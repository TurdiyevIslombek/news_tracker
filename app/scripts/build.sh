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
# The widget reuses the shared model/feed/cache/theme code, not the app's store.
WIDGET_SOURCES=("$APP_DIR"/Shared/{Models,Display,FeedClient,DayCache,Theme}.swift "$APP_DIR"/Widget/*.swift)
APP="$BUILD/AI Pulse.app"
APPEX="$APP/Contents/PlugIns/AIPulseWidget.appex"
rm -rf "$APP" && mkdir -p "$BUILD/obj" "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS"

bins=(); wbins=()
for arch in "${ARCHS[@]}"; do
  echo "• compiling $arch"
  xcrun swiftc "${OPT[@]}" -parse-as-library -swift-version 6 \
    -target "$arch-apple-macosx$MIN_OS" -sdk "$SDK" \
    -module-name AIPulse "${SOURCES[@]}" -o "$BUILD/obj/AIPulse-$arch"
  bins+=("$BUILD/obj/AIPulse-$arch")
  echo "• compiling widget $arch"
  # App extensions start in Foundation's _NSExtensionMain (as Xcode links them),
  # not in the main() that @main WidgetBundle generates: with that, ExtensionFoundation
  # traps on launch and the widget never reaches the gallery.
  xcrun swiftc "${OPT[@]}" -parse-as-library -application-extension -swift-version 6 \
    -target "$arch-apple-macosx$MIN_OS" -sdk "$SDK" \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -module-name AIPulseWidget "${WIDGET_SOURCES[@]}" -o "$BUILD/obj/AIPulseWidget-$arch"
  wbins+=("$BUILD/obj/AIPulseWidget-$arch")
done
lipo -create "${bins[@]}" -output "$APP/Contents/MacOS/AIPulse"
lipo -create "${wbins[@]}" -output "$APPEX/Contents/MacOS/AIPulseWidget"
SDK_VER="$(xcrun --sdk macosx --show-sdk-version)"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUM/" -e "s/__SDK__/$SDK_VER/g" \
  "$APP_DIR/Resources/Widget-Info.plist" > "$APPEX/Contents/Info.plist"

sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUM/" -e "s/__SDK__/$SDK_VER/g" \
  "$APP_DIR/Resources/Info.plist" > "$APP/Contents/Info.plist"
[[ -f "$APP_DIR/Resources/AppIcon.icns" ]] && cp "$APP_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/"

# Ad-hoc signature (no Apple Developer account needed). Gatekeeper will still ask
# downloaded copies to be opened via right-click → Open; see README.
# Sign inside-out: the sandboxed widget first (with its entitlements), then the app.
codesign --force --sign - --options runtime --timestamp=none \
  --entitlements "$APP_DIR/Resources/Widget.entitlements" "$APPEX"
codesign --force --sign - --options runtime --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
echo "✓ $APP ($(lipo -archs "$APP/Contents/MacOS/AIPulse"))"
