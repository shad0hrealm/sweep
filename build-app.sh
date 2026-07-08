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

# Sign with the stable self-signed identity when present (TCC keys permission
# grants on signing identity — a stable cert means grants survive rebuilds and
# auto-updates). Falls back to ad-hoc, where every build re-prompts.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Sweep Signing"; then
  codesign --force -s "Sweep Signing" "$APP"
else
  codesign --force -s - "$APP"
fi

echo "Built $APP"
