#!/bin/bash
# Builds ClaudeUsage.swift locally, installs it to ~/Applications
# and starts it automatically at login.
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Applications/ClaudeUsage.app"
LABEL="local.claude-usage-bar"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

# 1. Swift compiler (Apple Command Line Tools — already there if you use Homebrew)
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Apple Command Line Tools are missing."
  echo "An installer window will open — run this script again when it finishes."
  xcode-select --install || true
  exit 1
fi

# 2. Stop a running older version
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x ClaudeUsage 2>/dev/null || true

# 3. Build
echo "Building…"
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -O -parse-as-library ClaudeUsage.swift -o "$APP/Contents/MacOS/ClaudeUsage"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>ClaudeUsage</string>
  <key>CFBundleExecutable</key><string>ClaudeUsage</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

# Local ad-hoc signature (required on Apple Silicon; nothing is sent to Apple)
codesign --force --sign - "$APP" >/dev/null 2>&1

# 4. Start at login
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$APP/Contents/MacOS/ClaudeUsage</string></array>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF

# 5. Launch now (launchd also starts it at every login)
launchctl bootstrap "gui/$(id -u)" "$AGENT"

echo ""
echo "Done. Your limits are now in the menu bar and in the top-right corner of the desktop."
echo "If macOS asks about access to \"Claude Code-credentials\", click \"Always Allow\"."
echo "To uninstall: ./uninstall.sh"
