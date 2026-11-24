#!/bin/bash
# Package app/build/AI Pulse.app into a drag-to-install disk image.
#   app/scripts/package-dmg.sh            → app/build/AI-Pulse-<version>.dmg
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$APP_DIR/build"
APP="$BUILD/AI Pulse.app"
[[ -d "$APP" ]] || { echo "build the app first: app/scripts/build.sh" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$BUILD/AI-Pulse-$VERSION.dmg"
ROOT="$BUILD/dmg-root"

rm -rf "$ROOT" "$DMG" && mkdir -p "$ROOT"
cp -R "$APP" "$ROOT/"
ln -s /Applications "$ROOT/Applications"
cp "$APP_DIR/Resources/FirstLaunch.txt" "$ROOT/If macOS blocks the app.txt"

hdiutil create -volname "AI Pulse $VERSION" -srcfolder "$ROOT" -fs HFS+ -format UDZO -imagekey zlib-level=9 \
  -ov "$DMG" >/dev/null
rm -rf "$ROOT"
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
