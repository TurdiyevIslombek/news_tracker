#!/bin/bash
# Build "AI Pulse.app" (universal: Apple Silicon + Intel) with plain swiftc.
# Works with just the Xcode Command Line Tools; no Xcode project needed.
#
#   app/scripts/build.sh            # release build → app/build/AI Pulse.app
#   app/scripts/build.sh --debug    # faster, unoptimized, host arch only
#   VERSION=1.2.0 app/scripts/build.sh
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$APP_DIR/build"
VERSION="${VERSION:-0.1.0}"
BUILD_NUM="${BUILD_NUM:-$(date -u +%Y%m%d%H%M)}"
MIN_OS="14.0"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

OPT=(-O -whole-module-optimization)
ARCHS=(arm64 x86_64)
if [[ "${1:-}" == "--debug" ]]; then OPT=(-Onone -g); ARCHS=("$(uname -m)"); fi

SOURCES=("$APP_DIR"/Shared/*.swift "$APP_DIR"/AIPulse/*.swift)
APP="$BUILD/AI Pulse.app"
rm -rf "$APP" && mkdir -p "$BUILD/obj" "$APP/Contents/MacOS" "$APP/Contents/Resources"

bins=()
for arch in "${ARCHS[@]}"; do
  echo "• compiling $arch"
  xcrun swiftc "${OPT[@]}" -parse-as-library -swift-version 6 \
    -target "$arch-apple-macosx$MIN_OS" -sdk "$SDK" \
    -module-name AIPulse "${SOURCES[@]}" -o "$BUILD/obj/AIPulse-$arch"
  bins+=("$BUILD/obj/AIPulse-$arch")
done
lipo -create "${bins[@]}" -output "$APP/Contents/MacOS/AIPulse"

sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUM/" \
  "$APP_DIR/Resources/Info.plist" > "$APP/Contents/Info.plist"
[[ -f "$APP_DIR/Resources/AppIcon.icns" ]] && cp "$APP_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/"

# Ad-hoc signature (no Apple Developer account needed). Gatekeeper will still ask
# downloaded copies to be opened via right-click → Open; see README.
codesign --force --sign - --options runtime --timestamp=none "$APP"
echo "✓ $APP ($(lipo -archs "$APP/Contents/MacOS/AIPulse"))"
