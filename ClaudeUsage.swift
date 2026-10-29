// ClaudeUsage — Claude usage limits (5h session and weekly) in the macOS menu bar
// and on the desktop, with an optional "keep the Mac awake while Claude works" mode.
//
// Security in a nutshell:
//  • The only network request: GET https://api.anthropic.com/api/oauth/usage
//  • The OAuth token is only READ from where Claude Code keeps it
//    (~/.claude/.credentials.json or the macOS Keychain). It is never written,
//    logged or refreshed by this app.
//  • Keep-awake only looks at file MODIFICATION DATES in ~/.claude/projects,
//    never at file contents.
//  • No dependencies, no auto-updates, no telemetry.

import AppKit
import SwiftUI
import IOKit.pwr_mgt

// MARK: - Constants

let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
let redrawEvery: TimeInterval = 30       // countdown redraw (local, no network)
let maxBackoff: TimeInterval = 300       // after HTTP 429 the interval doubles, up to 5 min
let refreshChoices = [30, 60, 120]       // seconds, selectable in the menu

let keepAwakeHold: TimeInterval = 300    // after activity is seen, stay awake for 5 min…
let keepAwakeRecheck: TimeInterval = 240 // …but re-check after 4 min and extend or let go
let idleCheckEvery: TimeInterval = 60    // while not holding, look for activity every minute

// MARK: - Settings (UserDefaults)

enum Settings {
    static var d: UserDefaults { .standard }

    /// "pl" or "en". Defaults to the system language.
    static var language: String {
        get {
            if let v = d.string(forKey: "language") { return v }
            return (Locale.preferredLanguages.first ?? "en").hasPrefix("pl") ? "pl" : "en"
        }
        set { d.set(newValue, forKey: "language") }
    }
    static var clock24: Bool {
        get { d.object(forKey: "clock24") as? Bool ?? true }
        set { d.set(newValue, forKey: "clock24") }
    }
    static var refreshSeconds: Int {
        get { let v = d.integer(forKey: "refreshSeconds"); return refreshChoices.contains(v) ? v : 120 }
        set { d.set(newValue, forKey: "refreshSeconds") }
    }
    static var showDesktopWidget: Bool {
        get { d.object(forKey: "showDesktopWidget") as? Bool ?? true }
        set { d.set(newValue, forKey: "showDesktopWidget") }
    }
    static var resetClockInBar: Bool {
        get { d.object(forKey: "showResetClockInBar") as? Bool ?? true }
        set { d.set(newValue, forKey: "showResetClockInBar") }
    }
    static var keepAwake: Bool {
        get { d.object(forKey: "keepAwake") as? Bool ?? false }
        set { d.set(newValue, forKey: "keepAwake") }
    }
}

/// Localized string: Polish or English.
func L(_ pl: String, _ en: String) -> String { Settings.language == "pl" ? pl : en }

/// Claude Code's config directory (honours CLAUDE_CONFIG_DIR, like Claude Code itself).
func claudeDir() -> String {
    if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty { return custom }
    return NSHomeDirectory() + "/.claude"
}

// MARK: - Data model

struct Limit {
    let percent: Double?   // 0–100, nil = no data
    let resetsAt: Date?
}

struct Usage {
    let session: Limit     // rolling 5-hour window
    let weekly: Limit      // rolling 7-day window
}

enum AppError: Error {
    case noToken, tokenExpired, rateLimited, http(Int), badPayload, network

    var text: String {
        switch self {
        case .noToken:      return L("Brak tokenu — zaloguj się w Claude Code", "No token — log in to Claude Code")
        case .tokenExpired: return L("Token wygasł — uruchom `claude`", "Token expired — run `claude`")
        case .rateLimited:  return L("Za dużo zapytań — zwalniam", "Rate limited — slowing down")
        case .http(let c):  return L("Błąd API (\(c))", "API error (\(c))")
        case .badPayload:   return L("Nieznany format odpowiedzi", "Unknown response format")
        case .network:      return L("Brak połączenia", "No connection")
        }
    }
}

enum Status {
    case loading
    case ok
    case stale(AppError)   // showing last known data + the reason
    case error(AppError)   // no data at all

    /// Computed at display time, so switching language applies immediately.
    var message: String? {
        switch self {
        case .stale(let e), .error(let e): return e.text
        default: return nil
        }
    }
}

// MARK: - Token (read-only)

/// Pulls accessToken out of the JSON blob Claude Code stores.
/// Returns nil if the blob doesn't match; throws .tokenExpired if the token has expired.
func extractToken(_ blob: String) throws -> String? {
    guard let data = blob.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = root["claudeAiOauth"] as? [String: Any],
          let token = (oauth["accessToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !token.isEmpty
    else { return nil }

    if let expiresMs = (oauth["expiresAt"] as? NSNumber)?.doubleValue,
       Date(timeIntervalSince1970: expiresMs / 1000) < Date() {
        throw AppError.tokenExpired
    }
    return token
}

/// Reads a Keychain item via the system tool /usr/bin/security.
/// The first time, macOS asks for permission — click "Always Allow".
func readKeychain(service: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", service, "-w"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Same lookup order as Claude Code: env var → credentials file → Keychain.
func loadToken() throws -> String {
    if let env = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"], !env.isEmpty {
        return env
    }
    var sawExpired = false
    var sources: [() -> String?] = [
        { try? String(contentsOfFile: claudeDir() + "/.credentials.json", encoding: .utf8) }
    ]
    for service in ["Claude Code-credentials", "Claude Code"] {
        sources.append({ readKeychain(service: service) })
    }
    for source in sources {
        guard let blob = source() else { continue }
        do {
            if let token = try extractToken(blob) { return token }
        } catch {
            sawExpired = true
        }
    }
    throw sawExpired ? AppError.tokenExpired : AppError.noToken
}

// MARK: - API

/// The API returns dates like "2026-10-28T14:00:00.123456+00:00".
/// ISO8601DateFormatter can't parse 6 fractional digits, so the fraction is dropped.
func parseDate(_ raw: String?) -> Date? {
    guard var s = raw, !s.isEmpty else { return nil }
    if let r = s.range(of: #"\.\d+"#, options: .regularExpression) { s.removeSubrange(r) }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

func fetchUsage(token: String) async throws -> Usage {
    var req = URLRequest(url: usageURL, timeoutInterval: 15)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue("claude-usage-bar", forHTTPHeaderField: "User-Agent")

    let result: (Data, URLResponse)
    do {
        result = try await URLSession.shared.data(for: req)
    } catch {
        throw AppError.network
    }
    let (data, response) = result

    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    switch code {
    case 200: break
    case 401: throw AppError.tokenExpired
    case 429: throw AppError.rateLimited
    default:  throw AppError.http(code)
    }

    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw AppError.badPayload
    }
    func limit(_ key: String) -> Limit? {
        guard let d = root[key] as? [String: Any] else { return nil }
        return Limit(percent: (d["utilization"] as? NSNumber)?.doubleValue,
                     resetsAt: parseDate(d["resets_at"] as? String))
    }
    let session = limit("five_hour")
    let weekly = limit("seven_day")
    if session == nil && weekly == nil { throw AppError.badPayload }
    let empty = Limit(percent: nil, resetsAt: nil)
    return Usage(session: session ?? empty, weekly: weekly ?? empty)
}

// MARK: - Formatting

func makeFormatter(_ format: String) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: Settings.language == "pl" ? "pl_PL" : "en_US_POSIX")
    f.dateFormat = format
    return f
}

/// Time of day: "12:43" or "12:43 PM".
func clockString(_ date: Date) -> String {
    makeFormatter(Settings.clock24 ? "HH:mm" : "h:mm a").string(from: date)
}

/// Reset time: session → "12:43", weekly → "Thu, 21:00" / "czw. 21:00".
func resetClock(_ date: Date?, weekly: Bool) -> String {
    guard let date else { return "" }
    guard weekly else { return clockString(date) }
    let time = Settings.clock24 ? "HH:mm" : "h:mm a"
    let day = Settings.language == "pl" ? "EEE " : "EEE, "
    return makeFormatter(day + time).string(from: date)
}

/// Time until reset. compact: "2h13m" (menu bar), otherwise "2h 13m".
func timeLeft(_ date: Date?, now: Date, compact: Bool = false) -> String {
    guard let date else { return "—" }
    let s = Int(date.timeIntervalSince(now))
    if s <= 0 { return L("teraz", "now") }
    let d = s / 86_400, h = (s % 86_400) / 3_600, m = (s % 3_600) / 60
    let sep = compact ? "" : " "
    if d > 0 { return "\(d)d\(sep)\(h)h" }
    if h > 0 { return "\(h)h\(sep)\(String(format: "%02ld", m))m" }
    return "\(max(m, 1))m"
}

func pct(_ p: Double?) -> String {
    guard let p else { return "—" }
    return "\(Int(p.rounded()))%"
}

enum Level { case normal, warning, critical }
func level(_ p: Double?) -> Level {
    guard let p else { return .normal }
    return p >= 90 ? .critical : (p >= 75 ? .warning : .normal)
}

// MARK: - App state

@MainActor
final class Store: ObservableObject {
    @Published var usage: Usage?
    @Published var status: Status = .loading
    @Published var lastUpdate: Date?
    @Published var now = Date()      // changing this redraws the widget
    var rateLimited = false
    private var busy = false

    nonisolated init() {}

    func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            // Reading the token may wait for the Keychain prompt — keep it off the main thread.
            let token = try await Task.detached(priority: .utility) { try loadToken() }.value
            usage = try await fetchUsage(token: token)
            status = .ok
            rateLimited = false
            lastUpdate = Date()
        } catch {
            let e = (error as? AppError) ?? .network
            if case .rateLimited = e { rateLimited = true } else { rateLimited = false }
            status = usage == nil ? .error(e) : .stale(e)
        }
        now = Date()
    }
}

// MARK: - Keep-awake

/// Newest modification date of any Claude Code session transcript (*.jsonl).
/// Claude Code appends to these on every step of its work, so a recent date means
/// "Claude is working right now". Only dates are read, never file contents.
func latestClaudeCodeActivity() -> Date? {
    let root = URL(fileURLWithPath: claudeDir() + "/projects")
    let keys: [URLResourceKey] = [.contentModificationDateKey]
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles]) else { return nil }
    var latest: Date?
    for case let url as URL in walker {
        if walker.level > 4 { walker.skipDescendants(); continue }
        guard url.pathExtension == "jsonl",
              let modified = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate
        else { continue }
        if latest == nil || modified > latest! { latest = modified }
    }
    return latest
}

/// Holds a macOS power assertion (the same mechanism as `caffeinate -i`) while Claude is
/// active. The display may still sleep; the system won't idle-sleep. If the app quits
/// or crashes, macOS releases the assertion automatically.
@MainActor
final class KeepAwake {
    private var assertionID: IOPMAssertionID = 0
    private var timer: Timer?
    private var lastCheck = Date()
    private var baselinePercent: Double?
    private var baselineReset: Date?
    private(set) var awakeUntil: Date?

    private let currentUsage: () -> Usage?
    private let onChange: () -> Void

    init(currentUsage: @escaping () -> Usage?, onChange: @escaping () -> Void) {
        self.currentUsage = currentUsage
        self.onChange = onChange
    }

    var isHolding: Bool { assertionID != 0 }

    func setEnabled(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        guard on else {
            release()
            onChange()
            return
        }
        baselinePercent = nil
        baselineReset = nil
        lastCheck = Date().addingTimeInterval(-idleCheckEvery)   // catch activity from the last minute
        Task { await check() }
    }

    /// One decision point: was Claude active since the previous check?
    ///  • yes → stay awake for 5 more minutes, check again in 4
    ///  • no  → let the Mac sleep normally, keep looking every minute
    func check() async {
        let since = lastCheck
        let fileActivity = await Task.detached(priority: .utility) { latestClaudeCodeActivity() }.value
        let active = (fileActivity.map { $0 > since } ?? false) || sessionPercentIncreased()

        lastCheck = Date()
        snapshotBaseline()

        if active {
            hold()
            awakeUntil = Date().addingTimeInterval(keepAwakeHold)
            schedule(keepAwakeRecheck)
        } else {
            release()
            schedule(idleCheckEvery)
        }
        onChange()
    }

    /// Second signal (also covers the Claude apps, not just Claude Code):
    /// the 5-hour session percentage went up, or a new 5-hour window started.
    private func sessionPercentIncreased() -> Bool {
        guard let s = currentUsage()?.session, let p = s.percent, let base = baselinePercent else { return false }
        if let r = s.resetsAt {
            if let br = baselineReset, abs(r.timeIntervalSince(br)) > 600 { return p > 0 }  // new window
            if baselineReset == nil { return p > 0 }                                         // window just opened
        }
        return p > base + 0.01
    }

    private func snapshotBaseline() {
        let s = currentUsage()?.session
        baselinePercent = s?.percent
        baselineReset = s?.resetsAt
    }

    private func schedule(_ delay: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            Task { @MainActor in await self.check() }
        }
    }

    private func hold() {
        guard assertionID == 0 else { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            "PreventUserIdleSystemSleep" as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "ClaudeUsage: Claude is working" as CFString,
            &id)
        if result == kIOReturnSuccess { assertionID = id }
    }

    private func release() {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        awakeUntil = nil
    }
}

// MARK: - Desktop widget (SwiftUI)

func swiftColor(_ l: Level) -> Color {
    switch l {
    case .normal: return .accentColor
    case .warning: return .orange
    case .critical: return .red
    }
}

struct Bar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                if fraction > 0 {
                    Capsule().fill(color).frame(width: max(6, g.size.width * min(fraction, 1)))
                }
            }
        }
        .frame(height: 6)
    }
}

struct LimitRow: View {
    let title: String
    let limit: Limit?
    let weekly: Bool
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text(pct(limit?.percent))
                    .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(level(limit?.percent) == .normal ? Color.primary : swiftColor(level(limit?.percent)))
            }
            Bar(fraction: (limit?.percent ?? 0) / 100, color: swiftColor(level(limit?.percent)))
            HStack {
                Text(L("reset za ", "resets in ") + timeLeft(limit?.resetsAt, now: now))
                Spacer()
                Text(resetClock(limit?.resetsAt, weekly: weekly))
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }
}

struct WidgetView: View {
    @ObservedObject var store: Store

    var footer: String {
        if let m = store.status.message { return m }
        if let t = store.lastUpdate { return L("Zaktualizowano ", "Updated ") + clockString(t) }
        return L("Ładowanie…", "Loading…")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude").font(.system(size: 13, weight: .semibold))
            LimitRow(title: L("Sesja (5h)", "Session (5h)"), limit: store.usage?.session, weekly: false, now: store.now)
            LimitRow(title: L("Tydzień", "Week"), limit: store.usage?.weekly, weekly: true, now: store.now)
            Text(footer)
                .font(.system(size: 10))
                .foregroundStyle(store.status.message == nil ? Color.secondary : Color.orange)
                .lineLimit(1)
        }
        .padding(14)
        .frame(width: 240)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Lets the borderless widget be dragged by its background.
final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}

// MARK: - Menu bar + desktop window (AppKit)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    var statusItem: NSStatusItem!
    var desktopWindow: NSWindow?
    var refreshTimer: Timer?
    var redrawTimer: Timer?
    var currentDelay: TimeInterval = 0
    var keepAwake: KeepAwake!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // The delegate lives as long as the app, so capturing self strongly is fine.
        keepAwake = KeepAwake(currentUsage: { self.store.usage }, onChange: { self.updateStatusItem() })
        updateStatusItem()
        if Settings.showDesktopWidget { showDesktopWidget() }

        redrawTimer = Timer.scheduledTimer(withTimeInterval: redrawEvery, repeats: true) { _ in
            Task { @MainActor in self.redraw() }
        }
        // Data is stale after waking from sleep — refresh right away.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await self.refreshNow() }
        }

        Task {
            await refreshNow()
            if Settings.keepAwake { keepAwake.setEnabled(true) }
        }
    }

    /// Fetches data and schedules the next fetch.
    func refreshNow() async {
        await store.refresh()
        updateStatusItem()
        scheduleNextRefresh()
    }

    /// Normally the chosen interval. After HTTP 429: double it (up to 5 min) until the API answers again.
    func scheduleNextRefresh() {
        refreshTimer?.invalidate()
        let base = TimeInterval(Settings.refreshSeconds)
        currentDelay = store.rateLimited ? min(max(currentDelay, base) * 2, maxBackoff) : base
        refreshTimer = Timer.scheduledTimer(withTimeInterval: currentDelay, repeats: false) { _ in
            Task { @MainActor in await self.refreshNow() }
        }
    }

    /// Redraws the menu bar and widget (e.g. after a language or clock-format change).
    func redraw() {
        store.now = Date()
        updateStatusItem()
    }

    // Menu bar text: "☕ 5h 42% (2h13m · 12:43) │ 7d 18% (3d4h · Thu, 21:00)"
    // ☕ = keeping the Mac awake; the part after "·" can be turned off in the menu.
    func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let title = NSMutableAttributedString()

        // labelColor adapts to light/dark menu bars.
        func add(_ s: String, color: NSColor = .labelColor) {
            title.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]))
        }
        func tint(_ p: Double?) -> NSColor {
            switch level(p) {
            case .normal: return .labelColor
            case .warning: return .systemOrange
            case .critical: return .systemRed
            }
        }

        if keepAwake?.isHolding == true { add("☕ ") }
        if case .stale = store.status { add("⚠︎ ") }

        if let u = store.usage {
            add("5h ")
            add(pct(u.session.percent), color: tint(u.session.percent))
            add(" (\(barTime(u.session, weekly: false)))")
            add("  │  7d ")
            add(pct(u.weekly.percent), color: tint(u.weekly.percent))
            add(" (\(barTime(u.weekly, weekly: true)))")
        } else if case .error = store.status {
            add("Claude ⚠︎")
        } else {
            add("Claude …")
        }

        button.attributedTitle = title
        statusItem.menu = buildMenu()
    }

    func barTime(_ l: Limit, weekly: Bool) -> String {
        let left = timeLeft(l.resetsAt, now: store.now, compact: true)
        guard Settings.resetClockInBar, l.resetsAt != nil else { return left }
        return "\(left) · \(resetClock(l.resetsAt, weekly: weekly))"
    }

    // MARK: Menu

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        func info(_ text: String) {
            let entry = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            entry.isEnabled = false
            menu.addItem(entry)
        }
        func item(_ title: String, _ action: Selector, key: String = "", on: Bool? = nil, tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = self
            i.tag = tag
            if let on { i.state = on ? .on : .off }
            return i
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let sub = NSMenu()
            items.forEach { sub.addItem($0) }
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            parent.submenu = sub
            return parent
        }

        let now = store.now
        if let u = store.usage {
            info(L("Sesja (5h)", "Session (5h)") + ": \(pct(u.session.percent)) — "
                 + L("reset za ", "resets in ") + timeLeft(u.session.resetsAt, now: now)
                 + " (\(resetClock(u.session.resetsAt, weekly: false)))")
            info(L("Tydzień", "Week") + ": \(pct(u.weekly.percent)) — "
                 + L("reset za ", "resets in ") + timeLeft(u.weekly.resetsAt, now: now)
                 + " (\(resetClock(u.weekly.resetsAt, weekly: true)))")
        }
        if let m = store.status.message { info("⚠︎ \(m)") }
        if let t = store.lastUpdate { info(L("Zaktualizowano ", "Updated ") + clockString(t)) }
        if Settings.keepAwake {
            if let until = keepAwake?.awakeUntil, keepAwake?.isHolding == true {
                info("☕ " + L("Claude pracuje — Mac nie uśpi się do ", "Claude is working — Mac stays awake until ")
                     + clockString(until))
            } else {
                info(L("Claude nie pracuje — normalne usypianie", "Claude is idle — normal sleep"))
            }
        }

        menu.addItem(.separator())
        menu.addItem(item(L("Odśwież teraz", "Refresh now"), #selector(refreshClicked), key: "r"))
        menu.addItem(item(L("Nie usypiaj Maca, gdy Claude pracuje", "Keep Mac awake while Claude works"),
                          #selector(toggleKeepAwake), on: Settings.keepAwake))
        menu.addItem(item(L("Widget na pulpicie", "Desktop widget"), #selector(toggleDesktopWidget),
                          on: Settings.showDesktopWidget))
        menu.addItem(item(L("Godzina resetu w pasku", "Reset time in menu bar"), #selector(toggleResetClock),
                          on: Settings.resetClockInBar))

        menu.addItem(submenu(L("Język", "Language"), [
            item("Polski", #selector(setLanguage(_:)), on: Settings.language == "pl", tag: 0),
            item("English", #selector(setLanguage(_:)), on: Settings.language == "en", tag: 1),
        ]))
        menu.addItem(submenu(L("Format godziny", "Clock format"), [
            item(L("24-godzinny (21:00)", "24-hour (21:00)"), #selector(setClock(_:)), on: Settings.clock24, tag: 24),
            item(L("12-godzinny (9:00 PM)", "12-hour (9:00 PM)"), #selector(setClock(_:)), on: !Settings.clock24, tag: 12),
        ]))
        menu.addItem(submenu(L("Odświeżanie co…", "Refresh every…"), refreshChoices.map { secs in
            item(secs < 60 ? "\(secs) s" : "\(secs / 60) min", #selector(setRefresh(_:)),
                 on: Settings.refreshSeconds == secs, tag: secs)
        }))

        menu.addItem(.separator())
        menu.addItem(item(L("Otwórz claude.ai/settings/usage", "Open claude.ai/settings/usage"), #selector(openWeb)))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("Zakończ", "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    @objc func refreshClicked() { Task { await refreshNow() } }

    @objc func openWeb() {
        NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
    }

    @objc func toggleKeepAwake() {
        Settings.keepAwake.toggle()
        keepAwake.setEnabled(Settings.keepAwake)
        redraw()
    }

    @objc func toggleResetClock() {
        Settings.resetClockInBar.toggle()
        redraw()
    }

    @objc func setLanguage(_ sender: NSMenuItem) {
        Settings.language = sender.tag == 0 ? "pl" : "en"
        redraw()
    }

    @objc func setClock(_ sender: NSMenuItem) {
        Settings.clock24 = sender.tag == 24
        redraw()
    }

    @objc func setRefresh(_ sender: NSMenuItem) {
        Settings.refreshSeconds = sender.tag
        currentDelay = 0
        scheduleNextRefresh()
        redraw()
    }

    @objc func toggleDesktopWidget() {
        Settings.showDesktopWidget.toggle()
        if Settings.showDesktopWidget { showDesktopWidget() } else { desktopWindow?.orderOut(nil) }
        redraw()
    }

    // MARK: Desktop window

    func showDesktopWidget() {
        if let w = desktopWindow { w.orderFront(nil); return }

        let host = DraggableHostingView(rootView: WidgetView(store: store))
        let size = host.fittingSize
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        // Just above the desktop icons: the widget sits "on the desktop", below normal windows.
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        // Remember the position after dragging; first launch → top-right corner.
        let name = "ClaudeUsageDesktopWidget"
        if !w.setFrameUsingName(name), let screen = NSScreen.main?.visibleFrame {
            w.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 24, y: screen.maxY - size.height - 24))
        }
        w.setFrameAutosaveName(name)

        w.orderFront(nil)
        desktopWindow = w
    }
}

// MARK: - Entry point

@main
struct ClaudeUsageMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // no Dock icon
        withExtendedLifetime(delegate) { app.run() }
    }
}
