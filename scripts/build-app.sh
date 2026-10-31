#!/bin/sh
# swift build -> build/YK Touch Notifier.app -> ad-hoc codesign
set -eu
cd "$(dirname "$0")/.."
swift build -c release --product YKTouchNotifier
app="build/YK Touch Notifier.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
mkdir -p "$app/Contents/Resources"
cp Resources/Info.plist "$app/Contents/"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
cp "$(swift build -c release --show-bin-path)/YKTouchNotifier" "$app/Contents/MacOS/yk-touch-notifier"
codesign --force --sign "${SIGN_IDENTITY:--}" --options runtime "$app"
echo "built $app"
