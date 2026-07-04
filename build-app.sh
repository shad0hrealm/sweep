#!/bin/bash
# Builds Sweep.app into ./build using SwiftPM (no Xcode project required).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/Sweep.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Sweep "$APP/Contents/MacOS/Sweep"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc sign so TCC permission grants (e.g. Full Disk Access) stick across rebuilds.
codesign --force -s - "$APP"

echo "Built $APP"
