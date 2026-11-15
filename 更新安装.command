#!/bin/bash
cd "$(dirname "$0")"
# 只允许同时跑一个（后台双击有时会触发两次）
LOCK=/tmp/tfire-update.lock
mkdir "$LOCK" 2>/dev/null || { echo "已经有一个更新在跑，这个窗口退出"; exit 0; }
trap 'rmdir "$LOCK"' EXIT
mkdir -p build
LOG=build/last-update.log
{
  echo "== $(date)"
  ./scripts/build.sh && ./scripts/install.sh && echo UPDATE_OK
} 2>&1 | tee "$LOG"
