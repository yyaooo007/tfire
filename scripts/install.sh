#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="$HOME/Library/Caches/TfireBuild/Tfire.app"
DEST="$HOME/Applications/Tfire.app"
pkill -x Loukei || true
pkill -x Tfire || true
sleep 0.5
# 旧名字的 App 移进废纸篓（不永久删除）
OLD="$HOME/Applications/漏刻.app"
if [ -d "$OLD" ]; then mv "$OLD" "$HOME/.Trash/漏刻-$(date +%Y%m%d%H%M%S).app"; echo "旧版 漏刻.app 已移进废纸篓"; fi
mkdir -p "$HOME/Applications" build
rm -rf "$DEST"
ditto "$SRC" "$DEST"
echo "== 自检"
"$DEST/Contents/MacOS/Tfire" --report "build/report.txt"
"$DEST/Contents/MacOS/Tfire" --snapshot "build" || true
open "$DEST"
echo INSTALL_OK
