#!/bin/bash
# Removes ClaudeUsage: stops the app, removes the login item, the app and its settings.
LABEL="local.claude-usage-bar"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x ClaudeUsage 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/ClaudeUsage.app"
defaults delete "$LABEL" 2>/dev/null || true   # settings + widget position

echo "ClaudeUsage uninstalled."
