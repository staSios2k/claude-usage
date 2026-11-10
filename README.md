# ClaudeUsage

A tiny native macOS app that shows your Claude plan limits in the menu bar, shows a live status dot for every running Claude Code session, and can keep your Mac awake while Claude is working.

```
● ● ●  ☕ 5h 42% (2h13m · 12:43)  │  7d 18% (3d4h · Thu, 21:00)
```

One Swift file, no dependencies, built on your own machine.

> **Unofficial.** This project is not affiliated with or endorsed by Anthropic. It relies on an undocumented endpoint that may change at any time.

## Features

- **Menu bar:** 5-hour session usage and weekly usage, each with time left until reset and the reset time itself
- **Session dots:** one dot per running Claude Code session, updated every second. Click a dot to jump to that session. A dot shakes when its session needs you or finishes. See [below](#session-dots).
- **Colour warnings:** orange from 75%, red from 90%
- **Keep Mac awake while Claude works** (optional, off by default). See [below](#keep-mac-awake-while-claude-works).
- **Two languages:** Polski / English (defaults to your system language)
- **Clock format:** 24-hour (`21:00`) or 12-hour (`9:00 PM`)
- **Refresh interval:** 30 s, 1 min or 2 min, with automatic back-off when the API rate-limits
- Refreshes immediately after the Mac wakes from sleep
- No Dock icon; starts at login

Everything is configured from the menu that opens when you click the menu bar item.

## Requirements

- macOS 13 Ventura or newer
- [Claude Code](https://docs.claude.com/en/docs/claude-code) installed and logged in on this Mac, with a Pro or Max plan. The app reuses Claude Code's login.
- Apple Command Line Tools (`xcode-select --install`). The installer offers to install them if they're missing.

## Install

```bash
git clone https://github.com/staSios2k/claude-usage-bar.git
cd claude-usage-bar
./install.sh
```

The script compiles the app, installs it to `~/Applications/ClaudeUsage.app`, and registers a LaunchAgent so it starts at login.

On first launch macOS asks whether `security` may access **"Claude Code-credentials"** in your Keychain. Click **Always Allow**, otherwise the prompt comes back on every refresh.

To update, pull the latest code and run `./install.sh` again. Your settings are kept.

## Uninstall

```bash
./uninstall.sh
```

This removes the app, the LaunchAgent and the saved settings.

## Session dots

Left of the usage text there is one dot for every Claude Code session running on this Mac (terminal, VS Code or the Claude app). The dots sit in the same menu bar item as the usage text, so other apps' icons can never come between them. Each dot is clickable on its own (oldest session on the left); a click on the text opens the menu:

| Dot | Meaning |
|---|---|
| 🟢 green | Claude is working |
| 🟠 orange | Claude needs you: a permission prompt, a question or a dialog |
| ● dark green | Claude finished its task less than 30 seconds ago |
| ⚪ grey | Claude has finished and is idle |

Hover a dot to see the session's name and folder. **Click a dot** to go to that session:

- **VS Code** (and forks such as Cursor): the window with that folder comes to the front and the session's Claude tab opens.
- **Terminal / iTerm2:** the tab the session runs in is selected. The first time, macOS asks whether ClaudeUsage may control Terminal or iTerm2.
- **Anything else:** the app the session runs in comes to the front.

**Shake and sound when a session needs you or finishes** (on by default, under the dots option in the menu):

- A session turns **orange**: the macOS *Glass* sound plays and its dot shakes hard. It shakes again every 30 seconds until you answer or click the dot.
- A session goes from **green to grey** (its task is done): its dot shakes once, without a sound.

**How it works.** Claude Code keeps a small status file per running process in `~/.claude/sessions/<pid>.json` with the session's name, folder and status (`busy`, `waiting` or `idle`). ClaudeUsage reads these files once a second. Files left behind by sessions that have exited are ignored. Transcripts are never read.

## Keep Mac awake while Claude works

Long Claude Code tasks die when the Mac goes to sleep. With this option on, ClaudeUsage holds a macOS power assertion (the same mechanism `caffeinate -i` uses) only while Claude is actually working:

1. Every minute it checks whether Claude was active.
2. If it was, the Mac is kept awake for the next 5 minutes, and a ☕ appears in the menu bar.
3. After 4 minutes it checks again. If Claude is still active, it extends the hold by another 5 minutes. If not, it releases the hold and the Mac sleeps normally.

**How "Claude is active" is detected.** Either signal is enough:

| Signal | Covers | Notes |
|---|---|---|
| A Claude Code session file in `~/.claude/projects/**/*.jsonl` was modified since the last check | Claude Code | Primary signal. It is local and instant. **Only modification dates are read, never file contents.** |
| The 5-hour session percentage went up, or a new 5-hour window started | Claude Code, Claude apps, claude.ai | Coarse: on large plans a few minutes of work may not move the percentage by a full point. |

**Limitations:**
- Only *idle* sleep is prevented, and the display can still turn off. Closing a MacBook's lid on battery still puts it to sleep, because no app can override that.
- A single tool call that runs for more than 4 minutes without writing anything (for example a long build) may not count as activity.
- If the app quits or crashes, macOS releases the assertion automatically, so the Mac can never get stuck awake.

To see the hold from Terminal, run `pmset -g assertions | grep ClaudeUsage`.

## Security & privacy

The whole app is [`ClaudeUsage.swift`](ClaudeUsage.swift), about 1000 lines, and is worth reading before you install.

- **One network request:** `GET https://api.anthropic.com/api/oauth/usage`. There are no analytics, no update checks and no other hosts.
- **Token is read-only.** It is looked up the same way Claude Code does it: the `CLAUDE_CODE_OAUTH_TOKEN` env var, then `~/.claude/.credentials.json`, then the macOS Keychain. It is kept in memory only and is never written, logged or refreshed.
- **Session dots read status files only.** `~/.claude/sessions/*.json` holds each session's PID, name, folder and status. Your conversations (`~/.claude/projects`) are never opened.
- **No auto-update.** The code you read is the code that runs, until you choose to rebuild.
- **Local build.** The app is compiled on your Mac and ad-hoc signed. No prebuilt binaries are involved.
- `CLAUDE_CONFIG_DIR` is respected, just as Claude Code respects it.

## How it works

Claude Code's `/usage` command calls `api.anthropic.com/api/oauth/usage` with your OAuth token and the `anthropic-beta: oauth-2025-04-20` header. The response contains `five_hour` and `seven_day` objects with `utilization` (0–100) and `resets_at` (ISO 8601). ClaudeUsage calls the same endpoint.

## Known limitations

- **Undocumented API.** If Anthropic changes the endpoint, the app shows "Unknown response format" until the parser is updated.
- **Expired token.** Claude Code's token expires after some time without using `claude`. The app then shows the last known values with ⚠︎. Running `claude` once fixes it. The app deliberately doesn't refresh the token itself, so it can never log Claude Code out.
- **Notched MacBooks.** On these, macOS hides menu bar items that don't fit. If the text or the dots disappear, turn off **Reset time in menu bar** in the menu.
- **Session status format is undocumented.** The dots rely on Claude Code's internal `~/.claude/sessions` files. If a Claude Code update changes them, the dots may stay grey or disappear.

## License

[MIT](LICENSE)
