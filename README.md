# Agent Dock

一眼看清 Claude Code 和 Antigravity 里哪些任务正在跑、哪些跑完了还没看。

它由两部分组成：

- **Claude Code 插件**（`claude-plugin/`）：在 Claude 桌面端每个会话旁边加一个「会话」面板，按项目列出所有 Claude Code 会话；同时把会话状态和套餐用量写到 `~/.claude/agent-dock/`，供菜单栏程序读取。
- **macOS 菜单栏程序 AgentDock**（`macos/`）：点顶部菜单栏图标弹出下拉面板，左栏 Claude、右栏 Antigravity，点会话即可跳过去。

## 功能

- 会话按项目分组，每个项目默认显示最近 5 条，`see more` / `see less` 展开收起
- 状态一眼可见：橙色转圈是运行中，蓝点是停下后还没看过，灰色是已看过
- 时间范围切换：`6h` · `24h` · `7d` · `all`，默认 6h
- 菜单栏图标随状态变化：右上角转圈表示有任务在跑，旁边的数字是运行中的数量；实心点表示有未查看的
- Claude 栏显示套餐用量（5 小时额度、每周额度）和精确到分钟的重置时间
- 下拉面板顶部可以单独隐藏 Claude 或 Antigravity 一栏，选择会被记住
- 登录时自动启动；只在 Claude 或 Antigravity 运行时才出现在菜单栏

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
- Antigravity 的对话从它本地的 `~/.gemini/antigravity/conversation_summaries.db` 只读读取，Antigravity 那边不需要安装任何东西。

## 已知限制

- Antigravity 没有能直接打开某条对话的链接，点 Antigravity 的会话只会打开它的 Agent Manager。
- Antigravity 不告诉外部你正在看哪条对话，所以它的「未查看」只在从下拉面板点开、或对话重新开始运行时清除；对话停下时如果 Antigravity 在最前面，就不算未查看。
- Antigravity 的数据库格式没有公开文档，Antigravity 升级后可能需要跟着调整。
- 菜单栏的 Claude 数据依赖至少一个开着的 Claude 会话加载了插件；否则 Claude 栏会显示「未连接」。

## 开发

- 插件从仓库目录直接读取，改完在会话里运行 `/reload-plugins` 即可生效。
- 菜单栏程序改完运行 `macos/build.sh`，会重新编译、安装并重启。
- `AgentDock --render-icon <目录>` 会把菜单栏图标的四种状态导出成 PNG，方便检查。
