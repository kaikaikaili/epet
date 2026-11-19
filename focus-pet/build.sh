#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="dist/FocusPet.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/FocusPet "$APP/Contents/MacOS/FocusPet"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "built: $(pwd)/$APP"
