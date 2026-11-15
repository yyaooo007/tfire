#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Build on the internal disk: rm -rf on the external (exFAT) volume trips over ._ files.
OUT="$HOME/Library/Caches/TfireBuild"
APP="$OUT/Tfire.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ARCH="$(uname -m)"
swiftc -O -parse-as-library -target "$ARCH-apple-macos14.0" \
  Sources/*.swift -o "$APP/Contents/MacOS/Tfire"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" || echo "codesign 失败（链接器已做临时签名，仍可运行）"
echo BUILD_OK
