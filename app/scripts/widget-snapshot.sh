#!/bin/bash
# Render the widget in all sizes (light + dark) to PNGs: widget-snapshot.sh OUT_DIR [day.json]
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?output dir}"; DAY="${2:-$APP_DIR/Tests/Fixtures/day.json}"
mkdir -p "$OUT" "$APP_DIR/build/tests"
# Widget sources minus its @main bundle (the tool has its own @main).
SRC=("$APP_DIR"/Shared/{Models,Display,FeedClient,DayCache,Theme}.swift)
for f in "$APP_DIR"/Widget/*.swift; do [[ "$(basename "$f")" == "WidgetBundle.swift" ]] || SRC+=("$f"); done
xcrun swiftc -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macosx14.0" \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" "${SRC[@]}" "$APP_DIR/Tests/WidgetSnapshot.swift" \
  -o "$APP_DIR/build/tests/widget-snapshot"
"$APP_DIR/build/tests/widget-snapshot" "$OUT" "$DAY"
