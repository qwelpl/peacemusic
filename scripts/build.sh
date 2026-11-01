#!/bin/bash
# Builds build/Peace.app. Pass --run to launch it afterwards.
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release

app="build/Peace.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/PeaceMusic" "$app/Contents/MacOS/PeaceMusic"
cp Resources/Info.plist "$app/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app"

echo "Built $app"
if [ "${1:-}" = "--run" ]; then
    open "$app"
fi
