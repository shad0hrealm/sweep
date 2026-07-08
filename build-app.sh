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

# Signing priority (TCC keys permission grants on signing identity — a stable
# cert means grants survive rebuilds and auto-updates):
#   1. Developer ID (notarisable, zero Gatekeeper friction) — hardened runtime required
#   2. "Sweep Signing" self-signed (stable grants, local/family distribution)
#   3. Ad-hoc (every rebuild re-prompts TCC)
DEV_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)
if [ -n "$DEV_ID" ]; then
  codesign --force --options runtime --timestamp -s "$DEV_ID" "$APP"
  echo "Signed with: $DEV_ID"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Sweep Signing"; then
  codesign --force -s "Sweep Signing" "$APP"
else
  codesign --force -s - "$APP"
fi

echo "Built $APP"
