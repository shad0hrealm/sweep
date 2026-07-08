#!/bin/bash
# Cut a release: ./release.sh 1.5
# Bumps the version, builds, zips, tags, pushes, and publishes a GitHub release.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=${1:?usage: ./release.sh <version, e.g. 1.5>}

plutil -replace CFBundleShortVersionString -string "$VERSION" Resources/Info.plist
./build-app.sh
ditto -c -k --keepParent build/Sweep.app "build/Sweep-$VERSION.zip"

git add Resources/Info.plist
git diff --cached --quiet || git commit -m "Release $VERSION"
git tag "v$VERSION"
git push origin main --tags

gh release create "v$VERSION" "build/Sweep-$VERSION.zip" \
  --title "Sweep $VERSION" --generate-notes

echo "Released v$VERSION — machines with auto-update install it on their next scheduled scan."
