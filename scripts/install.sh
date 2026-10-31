#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
label=local.yk-touch-notifier
plist="$HOME/Library/LaunchAgents/$label.plist"
scripts/build-app.sh
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
rm -rf "$HOME/Applications/YK Touch Notifier.app"
cp -R "build/YK Touch Notifier.app" "$HOME/Applications/"
sed "s|__HOME__|$HOME|g" "launchd/$label.plist" > "$plist"
launchctl bootstrap "gui/$(id -u)" "$plist"
echo "installed; macOS will ask for notification permission on first start."
echo "logs: ~/Library/Logs/yk-touch-notifier.log"
