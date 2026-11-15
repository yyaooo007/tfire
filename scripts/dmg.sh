#!/bin/bash
# Build an Apple-silicon (arm64) Tfire.app and wrap it in dist/Tfire-<version>-arm64.dmg
set -euo pipefail
cd "$(dirname "$0")/.."
ARCH=arm64 ./scripts/build.sh
APP="$HOME/Library/Caches/TfireBuild/Tfire.app"
VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
STAGE="$HOME/Library/Caches/TfireBuild/dmg"
TMP="$HOME/Library/Caches/TfireBuild/Tfire-$VER-arm64.dmg"
rm -rf "$STAGE" "$TMP"
mkdir -p "$STAGE" dist
ditto "$APP" "$STAGE/Tfire.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Tfire $VER" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$TMP"
hdiutil verify "$TMP"
# mount and check what's inside
MNT=$(mktemp -d /tmp/tfire-dmg.XXXX)
hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$TMP" >/dev/null
echo "== DMG 内容"; ls -la "$MNT"
echo "== 架构"; lipo -archs "$MNT/Tfire.app/Contents/MacOS/Tfire"
echo "== 签名"; codesign -dv "$MNT/Tfire.app" 2>&1 | grep -E "Identifier|Signature|Format" || true
"$MNT/Tfire.app/Contents/MacOS/Tfire" --report "$HOME/Library/Caches/TfireBuild/dmg-report.txt" >/dev/null && echo "== DMG 里的 App 能运行（自检通过）"
hdiutil detach "$MNT" >/dev/null
cp "$TMP" "dist/"
cp "$HOME/Library/Caches/TfireBuild/Tfire.iconset/icon_512x512@2x.png" dist/icon-1024.png
echo "== $(ls -la dist/Tfire-$VER-arm64.dmg)"
shasum -a 256 "dist/Tfire-$VER-arm64.dmg"
echo DMG_OK
