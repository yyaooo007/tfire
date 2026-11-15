# Tfire — 菜单栏里的本机 token 用量

只读本机日志，不联网、不读钥匙串：
- Claude Code（CLI 与桌面 App 本地 Code 会话）：`~/.claude/projects/**/*.jsonl`
- Codex（桌面 App 与 CLI）：`~/.codex/sessions/**/*.jsonl`，归档 `~/.codex/archived_sessions/*.jsonl.zst`（需要 zstd）
- WorkBuddy：`~/.workbuddy/projects/*/*.jsonl`

索引缓存：`~/Library/Application Support/Tfire/cache.json`（删掉即重建）。
更新：双击 `更新安装.command`，日志 `build/last-update.log`，自检 `build/report.txt`。
