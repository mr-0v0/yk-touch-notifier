#!/bin/sh
# Nothing in ~/.gnupg was touched, so there is nothing else to undo.
set -eu
label=local.yk-touch-notifier
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$label.plist"
rm -rf "$HOME/Applications/YK Touch Notifier.app"
echo "uninstalled"
