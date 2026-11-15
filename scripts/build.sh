#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Build on the internal disk: rm -rf on the external (exFAT) volume trips over ._ files.
OUT="$HOME/Library/Caches/TfireBuild"
APP="$OUT/Tfire.app"
rm -rf "$APP" "$OUT/Tfire.iconset"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ARCH="${ARCH:-$(uname -m)}"
swiftc -O -parse-as-library -target "$ARCH-apple-macos14.0" \
  Sources/*.swift -o "$APP/Contents/MacOS/Tfire"
cp Info.plist "$APP/Contents/Info.plist"
# app icon, drawn by the app itself
"$APP/Contents/MacOS/Tfire" --iconset "$OUT/Tfire.iconset"
iconutil -c icns -o "$APP/Contents/Resources/Tfire.icns" "$OUT/Tfire.iconset"
codesign --force --sign - "$APP" || echo "codesign 失败（链接器已做临时签名，仍可运行）"
echo BUILD_OK
