// ClaudeUsage — Claude usage limits (5h session and weekly) in the macOS menu bar,
// live status dots for every running Claude Code session, and an optional
// "keep the Mac awake while Claude works" mode.
//
// Security in a nutshell:
//  • The only network request: GET https://api.anthropic.com/api/oauth/usage
//  • The OAuth token is only READ from where Claude Code keeps it
//    (~/.claude/.credentials.json or the macOS Keychain). It is never written,
//    logged or refreshed by this app.
//  • Keep-awake only looks at file MODIFICATION DATES in ~/.claude/projects,
//    never at file contents.
//  • Session dots read Claude Code's small per-process status files in
//    ~/.claude/sessions (pid, name, folder, busy/waiting/idle), never transcripts.
//  • No dependencies, no auto-updates, no telemetry.

import AppKit
import IOKit.pwr_mgt

// MARK: - Constants

let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
let redrawEvery: TimeInterval = 30       // countdown redraw (local, no network)
let maxBackoff: TimeInterval = 300       // after HTTP 429 the interval doubles, up to 5 min
let refreshChoices = [30, 60, 120]       // seconds, selectable in the menu

let keepAwakeHold: TimeInterval = 300    // after activity is seen, stay awake for 5 min…
let keepAwakeRecheck: TimeInterval = 240 // …but re-check after 4 min and extend or let go
let idleCheckEvery: TimeInterval = 60    // while not holding, look for activity every minute

let sessionPollEvery: TimeInterval = 1   // session dots: re-read ~/.claude/sessions every second
let waitingSound = "Glass"               // macOS system sound played when a session needs input
let recentlyFinishedFor: TimeInterval = 30 // after finishing a task, the dot is dark green for 30 s
let waitingReshakeEvery: TimeInterval = 30 // a waiting dot shakes again every 30 s until you respond

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
    static var sessionDots: Bool {
        get { d.object(forKey: "sessionDots") as? Bool ?? true }
        set { d.set(newValue, forKey: "sessionDots") }
    }
    static var waitingAlert: Bool {
        get { d.object(forKey: "waitingAlert") as? Bool ?? true }
        set { d.set(newValue, forKey: "waitingAlert") }
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
final class Store {
    var usage: Usage?
    var status: Status = .loading
    var lastUpdate: Date?
    var now = Date()                 // "now" for the countdowns, refreshed by the redraw timer
    var rateLimited = false
    private var busy = false

    nonisolated init() {}

    // The last good reading is kept on disk, so a restart (or a rate-limited API) still shows
    // numbers instead of nothing. They are marked ⚠︎ until the API answers again.
    private let cacheKey = "cachedUsage"

    var cacheAge: TimeInterval? {
        (UserDefaults.standard.dictionary(forKey: cacheKey)?["at"] as? Double)
            .map { Date().timeIntervalSince1970 - $0 }
    }

    func restoreCache() {
        guard usage == nil, let c = UserDefaults.standard.dictionary(forKey: cacheKey) else { return }
        func limit(_ key: String) -> Limit {
            let reset = (c[key + "Reset"] as? Double).map { Date(timeIntervalSince1970: $0) }
            // A window that has reset since then: the old percentage no longer means anything.
            let expired = reset.map { $0 < Date() } ?? true
            return Limit(percent: expired ? nil : c[key + "Percent"] as? Double, resetsAt: expired ? nil : reset)
        }
        usage = Usage(session: limit("session"), weekly: limit("weekly"))
        lastUpdate = (c["at"] as? Double).map { Date(timeIntervalSince1970: $0) }
    }

    private func saveCache(_ u: Usage) {
        var c: [String: Any] = ["at": Date().timeIntervalSince1970]
        for (key, l) in [("session", u.session), ("weekly", u.weekly)] {
            if let p = l.percent { c[key + "Percent"] = p }
            if let r = l.resetsAt { c[key + "Reset"] = r.timeIntervalSince1970 }
        }
        UserDefaults.standard.set(c, forKey: cacheKey)
    }

    func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            // Reading the token may wait for the Keychain prompt — keep it off the main thread.
            let token = try await Task.detached(priority: .utility) { try loadToken() }.value
            let fresh = try await fetchUsage(token: token)
            usage = fresh
            saveCache(fresh)
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

// MARK: - Claude Code sessions (status dots)

enum SessionState {
    case working   // Claude is running a turn
    case waiting   // Claude needs the user: a permission prompt, a question, a dialog
    case idle      // the turn is over

    var color: NSColor {
        switch self {
        case .working: return .systemGreen
        case .waiting: return .systemOrange
        case .idle:    return .systemGray
        }
    }
    var label: String {
        switch self {
        case .working: return L("pracuje", "working")
        case .waiting: return L("czeka na Ciebie", "needs your input")
        case .idle:    return L("bezczynna", "idle")
        }
    }
}

struct ClaudeSession {
    let pid: pid_t
    let id: String
    let name: String
    let cwd: String
    let entrypoint: String   // "cli", "claude-vscode", "claude-desktop", …
    let state: SessionState
    let startedAt: Double    // seconds since 1970
}

/// Parent PID, start time and controlling terminal of a process (sysctl, no subprocess).
/// nil = no such process.
func processInfo(_ pid: pid_t) -> (ppid: pid_t, start: Double, tty: dev_t)? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let t = info.kp_proc.p_un.__p_starttime
    return (info.kp_eproc.e_ppid, Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000, info.kp_eproc.e_tdev)
}

/// Every running Claude Code session on this Mac, oldest first (so dots don't jump around).
/// Claude Code keeps one small JSON file per process in ~/.claude/sessions with its
/// status: "busy", "waiting" (needs the user), "idle" or "shell" (idle, background shell running).
func loadSessions() -> [ClaudeSession] {
    let dir = claudeDir() + "/sessions"
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
    var out: [ClaudeSession] = []
    for name in names where name.hasSuffix(".json") {
        guard let data = FileManager.default.contents(atPath: dir + "/" + name),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (o["pid"] as? NSNumber)?.int32Value,
              let id = o["sessionId"] as? String,
              o["spare"] as? Bool != true          // pre-started process nobody uses yet
        else { continue }
        let startedAt = ((o["startedAt"] as? NSNumber)?.doubleValue ?? 0) / 1000
        // Skip files left behind by a session that has exited (or whose PID now belongs
        // to a newer process).
        guard let p = processInfo(pid), startedAt == 0 || p.start <= startedAt + 5 else { continue }

        let state: SessionState
        switch o["status"] as? String {
        case "busy":    state = .working
        case "waiting": state = .waiting
        default:        state = .idle
        }
        let cwd = o["cwd"] as? String ?? ""
        let title = (o["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (cwd as NSString).lastPathComponent
        out.append(ClaudeSession(pid: pid, id: id, name: title, cwd: cwd,
                                 entrypoint: o["entrypoint"] as? String ?? "",
                                 state: state, startedAt: startedAt))
    }
    return out.sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
}

/// The app a session runs in: the nearest regular (Dock) app among its parent processes,
/// e.g. Terminal, iTerm2, Visual Studio Code or Claude.
func hostApp(of pid: pid_t) -> NSRunningApplication? {
    var p = pid
    for _ in 0..<16 {
        guard let info = processInfo(p), info.ppid > 1 else { return nil }
        p = info.ppid
        if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular { return app }
    }
    return nil
}

/// First URL scheme an app registers ("vscode", "cursor", …).
func urlScheme(of appURL: URL) -> String? {
    guard let types = Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
    else { return nil }
    return types.lazy.compactMap { ($0["CFBundleURLSchemes"] as? [String])?.first }.first
}

/// Brings the user to a session: the right editor window and Claude tab, or the right
/// terminal tab. Falls back to just bringing its app to the front.
@MainActor
func focusSession(_ s: ClaudeSession) {
    guard let app = hostApp(of: s.pid), let appURL = app.bundleURL else {
        if s.entrypoint == "claude-desktop" {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Claude.app"))
        }
        return
    }
    let activate = NSWorkspace.OpenConfiguration()
    activate.activates = true

    // VS Code (and forks): opening the folder focuses the window that has it open,
    // then the Claude Code extension's own link reveals that session's tab.
    if s.entrypoint == "claude-vscode", let scheme = urlScheme(of: appURL), !s.cwd.isEmpty,
       let link = URL(string: "\(scheme)://anthropic.claude-code/open?session=\(s.id)") {
        NSWorkspace.shared.open([URL(fileURLWithPath: s.cwd)], withApplicationAt: appURL, configuration: activate) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let again = NSWorkspace.OpenConfiguration()
                again.activates = true
                NSWorkspace.shared.open([link], withApplicationAt: appURL, configuration: again)
            }
        }
        return
    }

    // Terminal / iTerm2: select the tab whose tty the session runs on.
    if let tty = processInfo(s.pid)?.tty, tty != -1, let dev = devname(tty, S_IFCHR) {
        let path = "/dev/" + String(cString: dev)
        var script: String?
        switch app.bundleIdentifier {
        case "com.apple.Terminal":
            script = """
            tell application "Terminal"
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is "\(path)" then
                    set selected of t to true
                    set index of w to 1
                  end if
                end repeat
              end repeat
              activate
            end tell
            """
        case "com.googlecode.iterm2":
            script = """
            tell application "iTerm2"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with ss in sessions of t
                    if tty of ss is "\(path)" then
                      select w
                      select t
                      select ss
                    end if
                  end repeat
                end repeat
              end repeat
              activate
            end tell
            """
        default: break
        }
        if let script {
            var err: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&err)
            if err == nil { return }
        }
    }

    NSWorkspace.shared.openApplication(at: appURL, configuration: activate)
}

/// The whole menu bar item in one view: one dot per session, then the usage text. Being a
/// single item, the dots can never be separated from the usage text by other apps' icons.
/// Every dot is clickable on its own; a click anywhere else opens the menu.
/// A dot shakes to get attention when its session needs you or has just finished.
final class SessionBarView: NSView, NSViewToolTipOwner {
    static let dotSize: CGFloat = 10
    static let cell: CGFloat = 16     // dot + 6 pt gap
    static let pad: CGFloat = 6       // left/right edge; also room for the shake

    final class Dot {
        let layer = CALayer()
        var session: ClaudeSession
        var finishedAt: Date?         // when the session went from working to idle
        var acknowledged = false      // clicked while waiting → stop nagging
        var lastShake = Date.distantPast
        init(_ s: ClaudeSession) {
            session = s
            layer.cornerRadius = SessionBarView.dotSize / 2
        }
    }

    var onWidthChange: ((CGFloat) -> Void)?
    var onDotClick: ((ClaudeSession) -> Void)?
    var onTextClick: (() -> Void)?

    private var dots: [Dot] = []      // display order: oldest session first
    private var byID: [String: Dot] = [:]
    private var text = NSAttributedString()
    private var lastWidth: CGFloat = -1

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func setText(_ t: NSAttributedString) {
        text = t
        needsDisplay = true
        relayout()
    }

    /// Syncs the dots with the running sessions. Returns true if a session just started
    /// waiting for the user (the caller plays the sound). `alerts` is false on the first read.
    @discardableResult
    func apply(_ list: [ClaudeSession], alerts: Bool) -> Bool {
        let ids = Set(list.map(\.id))
        for (id, dot) in byID where !ids.contains(id) {
            dot.layer.removeFromSuperlayer()
            byID[id] = nil
        }
        var startedWaiting = false
        var ordered: [Dot] = []
        for s in list {
            guard let dot = byID[s.id] else {
                let dot = Dot(s)
                byID[s.id] = dot
                layer?.addSublayer(dot.layer)
                ordered.append(dot)
                continue
            }
            let before = dot.session.state
            if before == .working && s.state == .idle { dot.finishedAt = Date() }
            else if s.state != .idle { dot.finishedAt = nil }
            if s.state != .waiting { dot.acknowledged = false }
            dot.session = s
            ordered.append(dot)
            guard alerts else { continue }
            if s.state == .waiting && before != .waiting {
                startedWaiting = true
                shake(dot)
            } else if s.state == .idle && before == .working {
                shake(dot)                                     // finished its task
            } else if s.state == .waiting, !dot.acknowledged,
                      Date().timeIntervalSince(dot.lastShake) >= waitingReshakeEvery {
                shake(dot)                                     // still waiting: keep nagging
            }
        }
        dots = ordered
        relayout()
        return startedWaiting
    }

    private var dotsWidth: CGFloat { CGFloat(dots.count) * Self.cell }

    private func color(_ d: Dot) -> NSColor {
        // Just finished: dark green for a while, then grey.
        if d.session.state == .idle, let f = d.finishedAt, Date().timeIntervalSince(f) < recentlyFinishedFor {
            return NSColor.systemGreen.blended(withFraction: 0.45, of: .black) ?? .systemGreen
        }
        return d.session.state.color
    }

    private func relayout() {
        let width = (Self.pad * 2 + dotsWidth + text.size().width).rounded(.up)
        if width != lastWidth {
            lastWidth = width
            onWidthChange?(width)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, d) in dots.enumerated() {
            d.layer.frame = NSRect(x: Self.pad + CGFloat(i) * Self.cell,
                                   y: ((bounds.height - Self.dotSize) / 2).rounded(),
                                   width: Self.dotSize, height: Self.dotSize)
            d.layer.backgroundColor = color(d).cgColor
        }
        CATransaction.commit()
        removeAllToolTips()
        for i in dots.indices { addToolTip(cell(i), owner: self, userData: nil) }
    }

    override func layout() {
        super.layout()
        relayout()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let size = text.size()
        text.draw(at: NSPoint(x: Self.pad + dotsWidth, y: ((bounds.height - size.height) / 2).rounded()))
    }

    /// Clickable area of a dot: the full height, the dot plus its gap.
    private func cell(_ i: Int) -> NSRect {
        NSRect(x: Self.pad - 2 + CGFloat(i) * Self.cell, y: 0, width: Self.cell, height: bounds.height)
    }

    private func dotIndex(at p: NSPoint) -> Int? {
        dots.indices.first { cell($0).contains(p) }
    }

    /// A hard side-to-side shake with a hop and a swell, twice. About 1.3 s.
    private func shake(_ d: Dot) {
        d.lastShake = Date()
        let x = CAKeyframeAnimation(keyPath: "transform.translation.x")
        x.values = [0, -4, 4, -4, 4, -3.5, 3.5, -2.5, 2.5, 0]
        let y = CAKeyframeAnimation(keyPath: "transform.translation.y")   // the menu bar has room above and below
        y.values = [0, 6, -1, 4, -1, 2, 0]
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [1, 1.35, 1.1, 1.25, 1]
        let group = CAAnimationGroup()
        group.animations = [x, y, scale]
        group.duration = 0.65
        group.repeatCount = 2
        d.layer.add(group, forKey: "shake")
    }

    /// Transparent to the mouse: the menu bar button receives the click (and calls its
    /// action), and the action asks this view which dot, if any, was hit.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// `windowPoint` is the click location in the status item window's coordinates.
    func click(atWindowPoint windowPoint: NSPoint) {
        let p = convert(windowPoint, from: nil)
        if let i = dotIndex(at: p) {
            let d = dots[i]
            d.acknowledged = true
            d.layer.removeAllAnimations()
            onDotClick?(d.session)
        } else {
            onTextClick?()
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        guard let i = dotIndex(at: point) else { return "" }
        let s = dots[i].session
        return "\(s.name) — \(s.state.label)\n\((s.cwd as NSString).abbreviatingWithTildeInPath)"
    }
}

// MARK: - Menu bar (AppKit)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    var statusItem: NSStatusItem!
    var refreshTimer: Timer?
    var redrawTimer: Timer?
    var currentDelay: TimeInterval = 0
    var keepAwake: KeepAwake!

    // Session dots live inside the same menu bar item, left of the usage text.
    let barView = SessionBarView()
    var sessionTimer: Timer?
    var sessionsRead = false               // the first read is silent (no sound/shake at startup)
    var readingSessions = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Leftovers from the desktop widget, which no longer exists.
        UserDefaults.standard.removeObject(forKey: "showDesktopWidget")
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame ClaudeUsageDesktopWidget")
        UserDefaults.standard.removeObject(forKey: "NSStatusItem VisibleCC ClaudeUsageSessionDots")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            barView.frame = button.bounds
            barView.autoresizingMask = [.width, .height]
            button.addSubview(barView)
        }
        statusItem.button?.target = self
        statusItem.button?.action = #selector(barClicked)
        statusItem.button?.sendAction(on: [.leftMouseDown])
        barView.onWidthChange = { self.statusItem.length = $0 }
        barView.onDotClick = { focusSession($0) }
        barView.onTextClick = { self.showMenu() }
        // The delegate lives as long as the app, so capturing self strongly is fine.
        keepAwake = KeepAwake(currentUsage: { self.store.usage }, onChange: { self.updateStatusItem() })
        updateStatusItem()
        setSessionDots(Settings.sessionDots)

        redrawTimer = Timer.scheduledTimer(withTimeInterval: redrawEvery, repeats: true) { _ in
            Task { @MainActor in self.redraw() }
        }
        // Data is stale after waking from sleep — refresh right away.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await self.refreshNow() }
        }

        // Show the last known numbers right away. If they are fresh enough, don't ask the API
        // again yet, so restarting the app never causes a rate limit.
        store.restoreCache()
        updateStatusItem()
        Task {
            if let age = store.cacheAge, age >= 0, age < TimeInterval(Settings.refreshSeconds), store.usage != nil {
                store.status = .ok
                scheduleNextRefresh()
            } else {
                await refreshNow()
            }
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

    /// Redraws the menu bar (e.g. after a language or clock-format change).
    func redraw() {
        store.now = Date()
        updateStatusItem()
    }

    // Menu bar text: "☕ 5h 42% (2h13m · 12:43) │ 7d 18% (3d4h · Thu, 21:00)"
    // ☕ = keeping the Mac awake; the part after "·" can be turned off in the menu.
    func updateStatusItem() {
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

        barView.setText(title)
    }

    func barTime(_ l: Limit, weekly: Bool) -> String {
        let left = timeLeft(l.resetsAt, now: store.now, compact: true)
        guard Settings.resetClockInBar, l.resetsAt != nil else { return left }
        return "\(left) · \(resetClock(l.resetsAt, weekly: weekly))"
    }

    // MARK: Session dots

    func setSessionDots(_ on: Bool) {
        sessionTimer?.invalidate()
        sessionTimer = nil
        barView.apply([], alerts: false)
        sessionsRead = false
        guard on else { return }
        sessionTimer = Timer.scheduledTimer(withTimeInterval: sessionPollEvery, repeats: true) { _ in
            Task { @MainActor in await self.pollSessions() }
        }
        Task { await pollSessions() }
    }

    func pollSessions() async {
        guard !readingSessions else { return }
        readingSessions = true
        defer { readingSessions = false }
        let list = await Task.detached(priority: .utility) { loadSessions() }.value
        guard sessionTimer != nil else { return }   // turned off meanwhile
        let startedWaiting = barView.apply(list, alerts: sessionsRead && Settings.waitingAlert)
        if startedWaiting { NSSound(named: waitingSound)?.play() }
        sessionsRead = true
    }

    @objc func barClicked() {
        // Where the mouse is right now, in the status item window's coordinates. This does not
        // depend on which window the event claims to belong to.
        guard let window = statusItem.button?.window else { return showMenu() }
        let p = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        barView.click(atWindowPoint: p)
    }

    /// Opens the menu under the item (it is built now, so it is always current).
    func showMenu() {
        statusItem.menu = buildMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
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
        menu.addItem(item(L("Kropki sesji Claude w pasku", "Claude session dots in menu bar"),
                          #selector(toggleSessionDots), on: Settings.sessionDots))
        let alert = item(L("Trzęsienie i dźwięk, gdy sesja czeka lub skończy", "Shake and sound when a session needs you or finishes"),
                         #selector(toggleWaitingAlert), on: Settings.waitingAlert)
        alert.isEnabled = Settings.sessionDots
        alert.indentationLevel = 1
        menu.addItem(alert)
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

    @objc func toggleSessionDots() {
        Settings.sessionDots.toggle()
        setSessionDots(Settings.sessionDots)
        redraw()
    }

    @objc func toggleWaitingAlert() {
        Settings.waitingAlert.toggle()
        if Settings.waitingAlert { NSSound(named: waitingSound)?.play() }   // preview
        redraw()
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
