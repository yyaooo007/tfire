#!/bin/bash
cd "$(dirname "$0")"
LOCK=/tmp/tfire-update.lock
mkdir "$LOCK" 2>/dev/null || { echo "已经有一个任务在跑，这个窗口退出"; exit 0; }
trap 'rmdir "$LOCK"' EXIT
mkdir -p build
./scripts/dmg.sh 2>&1 | tee build/last-dmg.log
