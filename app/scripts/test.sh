#!/bin/bash
# Run the shared-code tests against fixtures taken from the real feed.
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$APP_DIR/build/tests"
mkdir -p "$OUT"
# Shared/ minus SwiftUI-only files, so the runner stays a plain CLI tool.
SRC=()
for f in "$APP_DIR"/Shared/*.swift; do [[ "$(basename "$f")" == "Theme.swift" ]] || SRC+=("$f"); done
xcrun swiftc -swift-version 6 -target "$(uname -m)-apple-macosx14.0" -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  "${SRC[@]}" "$APP_DIR/Tests/main.swift" -o "$OUT/run-tests"
"$OUT/run-tests" "$APP_DIR/Tests/Fixtures"
