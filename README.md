# Tfire — 菜单栏里的本机 token 用量

macOS 菜单栏小工具：一团火焰加今天的 token 数。点开看 Claude Code、Codex、WorkBuddy、Gemini 各自的用量、30 天走势、模型排行和订阅额度。

- 有 agent 正在消耗 token 时，火焰会燃烧（摆动约 8 秒）
- 任何订阅额度（Codex 5 小时 / 每周、WorkBuddy 各模型）到 90%、或 Gemini 桌面 App 报超额时，火焰红闪 10 秒提醒一次
- 「按日」页签可以一天天往前翻历史；点任意一根 30 天细柱直接跳到那一天，鼠标划过细柱显示当天数字
- 只读本机日志，不联网、不读钥匙串

## 安装（Apple 芯片 Mac，macOS 14 及以上）

1. 从 Releases 下载最新的 `Tfire-<版本>-arm64.dmg`（也在仓库的 `release/` 文件夹里），打开后把 Tfire 拖进「应用程序」。
2. 这个 App 没有 Apple 开发者签名，第一次打开会被拦：在「系统设置 → 隐私与安全性」里点「仍要打开」。
   或者在终端里运行一次：`xattr -dr com.apple.quarantine /Applications/Tfire.app`
3. 火焰出现在菜单栏右上角。点「…」可以设置登录时启动、菜单栏显示方式。

## 读取的数据

- Claude Code（CLI 与桌面 App 本地 Code 会话）：`~/.claude/projects/**/*.jsonl`
- Codex（桌面 App 与 CLI）：`~/.codex/sessions/**/*.jsonl`，归档 `~/.codex/archived_sessions/*.jsonl.zst`（需要 zstd）
- WorkBuddy：`~/.workbuddy/projects/*/*.jsonl`（含各模型订阅额度）
- Gemini CLI：`~/.gemini/tmp/*/chats/*.json`（真实 token）
- Gemini 桌面 App：`~/Library/Caches/com.google.GeminiMacOS/Gemini/*/ChatInfo2.store`（只有消息数、对话数；App 的 token 在 Google 服务器上，本机没有）和它日志里的超额状态

索引缓存：`~/Library/Application Support/Tfire/cache.json`（删掉即重建）。

## 从源码构建

需要 Xcode 命令行工具（`xcode-select --install`），不需要完整 Xcode。

- `更新安装.command`：编译并安装到 `~/Applications/Tfire.app`，日志 `build/last-update.log`，自检 `build/report.txt`
- `打包DMG.command`：编译 arm64 版本并打成 `dist/Tfire-<版本>-arm64.dmg`
