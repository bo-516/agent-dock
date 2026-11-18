# Agent Dock

一眼看清 Claude Code、Codex 和 Antigravity 里哪些任务正在跑、哪些跑完了还没看。

它由两部分组成：

- **Claude Code 插件**（`claude-plugin/`）：在 Claude 桌面端每个会话旁边加一个「会话」面板，按项目列出所有 Claude Code 会话；同时把会话状态和套餐用量写到 `~/.claude/agent-dock/`，供菜单栏程序读取。
- **macOS 菜单栏程序 AgentDock**（`macos/`）：点顶部菜单栏图标弹出下拉面板，依次并排展示 Claude、Codex、Antigravity 三栏，点会话即可跳过去。

## 功能

- 会话按项目分组，每个项目默认显示最近 5 条，`see more` / `see less` 展开收起
- 状态一眼可见：橙色转圈是运行中，蓝点是停下后还没看过，灰色是已看过
- 时间范围切换：`6h` · `24h` · `7d` · `all`，默认 6h
- 菜单栏图标随状态变化：右上角转圈表示有任务在跑，旁边的数字是运行中的数量；实心点表示有未查看的
- 三栏都显示套餐用量（5 小时、每周等）和精确到分钟的重置时间；Antigravity 按模型组分开（Gemini、Claude / GPT）
- 下拉面板顶部可以单独隐藏 Claude、Codex 或 Antigravity 任意一栏，选择会被记住
- 点顶部的「常驻」把面板固定在屏幕上：切换应用、打开会话都不会收起，按住顶栏空白处可以拖到任意位置；再点一次恢复点别处自动收起
- 鼠标在某条会话上停 0.4 秒，鼠标旁边会弹出预览卡片（尽量落在面板内，放不下时自动换到左边、上下），显示最近的提问、思考过程、工具步骤和回复；回复按 Markdown 显示标题、列表、表格和代码；运行中的会话每 1.5 秒刷新一次
- 面板是中性黑的毛玻璃，背后的窗口会模糊透出来，不跟随系统浅色模式
- 登录时自动启动；只在 Claude、Codex（桌面端或 CLI 会话）或 Antigravity 运行时才出现在菜单栏

### 不计入的会话

三边都不显示、也不计数：

- `/btw` 的旁支问询（桌面端和 CLI 都算）
- 由其他会话派生出来的会话（Claude 的 fork、任务卡片启动的会话；Codex 的 subagent、guardian review、非交互 `codex exec`；Antigravity 的子 Agent、sidekick）
- 还没发过消息的新会话（以及 Codex 中已归档的会话）

## 安装

需要 macOS 13 以上、Xcode 命令行工具（`swiftc`），以及 Claude 桌面端。

### 1. Claude Code 插件

在终端里：

```bash
claude plugin marketplace add bo-516/agent-dock
```

```bash
claude plugin install agent-dock@agent-dock
```

或者在 Claude 桌面端：点输入框旁的 +，选 Plugins → Add marketplace，填 `bo-516/agent-dock`，再添加 `agent-dock` 插件。

装好后，已经打开的会话里运行一次 `/reload-plugins`。

### 2. 菜单栏程序

```bash
git clone https://github.com/bo-516/agent-dock.git
```

```bash
agent-dock/macos/build.sh
```

脚本会编译 `AgentDock.app`、安装到 `~/Applications` 并启动。第一次启动时会把自己加入登录项，可以在下拉面板底部的「登录时自动启动」或「系统设置 → 通用 → 登录项」里关掉。

## 使用

- **会话面板**：在任意 Claude 会话的输入框里输入 `/sessions` 打开或关闭；面板右上角的 ✕ 也能关。开关状态在所有会话间共用。
- **菜单栏**：点图标打开下拉面板，点会话行跳转，点空白处收起。

## 工作原理

- 每个 Claude 会话都会加载插件，但同一时间只有一个会话负责通过 Claude 桌面端的会话接口读取列表，写入 `~/.claude/agent-dock/state.json`；它停止后，其他会话在约 12 秒内接手。「未查看」由插件根据当前窗口里显示的会话判断。
- 套餐用量由拿到最新读数的会话写入 `~/.claude/agent-dock/usage.json`，数据来自 Claude Code 最近一次 API 响应。
- Codex 的本地会话、项目和已读回执从 `~/.codex/state_*.sqlite` 只读读取；运行状态通过 `~/.codex/thread-writer-locks/*.lock` 的进程文件锁结合 `~/.codex/thread_history_*.sqlite` 的最新 turn 状态判断，点击会话通过 `codex://threads/<id>` 直接打开对应会话。Codex 那边不需要安装任何东西。
- Codex 的套餐额度通过内置或本机安装的 `codex app-server` 标准 JSON-RPC 接口（`account/rateLimits/read`）按需查询。
- Antigravity 的对话从它本地的 `~/.gemini/antigravity/conversation_summaries.db` 只读读取，Antigravity 那边不需要安装任何东西。
- Antigravity 的额度来自它本地语言服务的额度接口（Agent Manager 自己显示额度用的也是它）。AgentDock 每次请求前从该进程的启动参数里读取访问令牌和监听端口，令牌只在内存里使用，不写入任何地方。
- 悬停预览只在鼠标停在某条会话上时，只读读取这一条会话的本地记录：Claude 读 `~/.claude/projects/*/<CLI 会话 id>.jsonl`（会话 id 的对应关系来自桌面端的 `claude-code-sessions`）；Codex 读 `~/.codex/thread_history_*.sqlite`，还没写进去的新会话读它的 rollout 文件；Antigravity 读 `~/.gemini/antigravity/brain/<对话 id>/.system_generated/logs/transcript.jsonl`。只读文件末尾一段，不写入任何文件。

## 已知限制

- Antigravity 没有能直接打开某条对话的链接，点 Antigravity 的会话只会打开它的 Agent Manager。
- Antigravity 不告诉外部你正在看哪条对话，所以它的「未查看」只在从下拉面板点开、或对话重新开始运行时清除；对话停下时如果 Antigravity 在最前面，就不算未查看。（Codex 桌面端会话使用其自带的 `thread_read_receipts` 同步已读状态；无回执的 CLI 会话采用同样的前台判断兜底。）
- Codex 的云端沙盒会话若未落地到本地 `~/.codex/state_*.sqlite`，不会出现在列表里。
- Codex 和 Antigravity 的本地数据库格式没有公开稳定性承诺，客户端大版本升级后可能需要跟着调整。
- Claude 的「还没发消息」是按标题判断的（空标题或默认标题），没有消息数可查。
- 菜单栏的 Claude 数据依赖至少一个开着的 Claude 会话加载了插件；否则 Claude 栏会显示「未连接」。

## 开发

- 插件从仓库目录直接读取，改完在会话里运行 `/reload-plugins` 即可生效。
- 菜单栏程序改完运行 `macos/build.sh`，会重新编译、安装并重启。
- `AgentDock --render-icon <目录>` 会把菜单栏图标的四种状态导出成 PNG，方便检查。
- `AgentDock --print-quota` 会打印读到的 Codex 与 Antigravity 额度后退出。
- `AgentDock --print-conversations` 会打印读到的 Codex 与 Antigravity 对话（以及读取失败的原因）后退出。
- `AgentDock --print-preview` 会取三个来源各自最近的一条会话，打印悬停预览读到的内容后退出。
