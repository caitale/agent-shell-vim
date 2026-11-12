# Proposal

## Why

ACP 协议闭环已在 `research/acp-spike/` 完成三 agent 实测（mock / claude-agent-acp / pi-geohar 桥），可行性无遗留疑问。但 spike 代码是单文件验证品（`acp.vim` 197 行全在一处、命令前缀 Acp、全局变量切换 agent），不可维护、不可分发。roadmap M0 要求在正式插件结构下重建这些已验证的能力，让后续 M1–M5 有可生长的骨架。

## What Changes

- 新建 `plugin/agent-shell.vim` 入口：定义 `:AgentStart / :AgentStop / :AgentOpen / :AgentSend / :AgentPermAllow / :AgentPermReject` 命令与配置项（`g:agent_shell_agents` 自定义 agent 表；`g:agent_shell_verbose` stderr 透传；`g:agent_shell_debug` 原始流量落盘路径——后两者与自定义表均为 spike 已有能力的等价迁移，见 `research/acp-spike/acp.vim` v3 的 `g:acp_verbose`/`g:acp_debug`/`g:acp_agent_cmd`）
- 新建 `autoload/agent_shell/` 四模块（vim9script `import autoload`）：
  - `protocol.vim`：job 管理 + JSON-RPC 按行分帧 + 请求 id 关联 + stderr 降噪 + 调试落盘（spike 等价迁移）
  - `session.vim`：ACP 会话状态机（initialize / session/new / prompt / stopReason / 权限挂起）
  - `render.vim`：update 类型 → 聊天 buffer 渲染（承接 spike 的 HandleUpdate，含 available_commands/thought/usage 类型——thought/usage 为提示级渲染，spike 冒烟已观测到这两类）；`:AgentOpen` 窗口与 buffer 内按键（CR 发送 / y/n 答复，spike OpenChat 等价迁移）
  - `presets.vim`：内置三 agent preset（mock / claude / pi），`:AgentStart <preset>` 一行切换；不碰凭证（凭证全在 agent 侧，已实证）
- 测试迁移：mock 主流程 7 断言 + 拒绝分支 2 断言迁至 `t/`，headless 跑法不变；补 preset 解析与噪音行容错的最小断言；`mock_agent.py` 移入 `t/` 作为测试夹具随插件分发；真实 agent 手动冒烟脚本参数化迁移（不进 CI）
- 新增 `.github/workflows/test.yml`：action-setup-vim 装 Vim 9.1/9.2 矩阵跑 headless 测试
- 为 M1 预留接口：render 模块留输入区挂载点（UI 基线表 M0 预留项）
- **不新增任何功能**——能力与 spike 持平（M0 出口判据），结构模块化、测试可重复、preset 一行切换

## Capabilities

**New Capabilities**（首批 spec，当前 `openspec/specs/` 为空）：

- `acp-transport`：ACP agent 进程的启动/停止与 JSON-RPC stdio 传输（job 生命周期、按行分帧、请求-响应 id 关联、stderr 降噪、调试落盘）
- `acp-session`：ACP 会话状态机（握手→建会话→轮次→权限审批，含 stopReason 语义与 wire format 判别）
- `agent-presets`：内置与用户自定义 agent preset 的解析与选择（mock/claude/pi；不涉凭证）

**Modified Capabilities**：无（无既有 spec）。

## Impact

- **新增代码**：`plugin/`、`autoload/agent_shell/`、`t/`、`.github/workflows/`
- **依赖**：运行时零依赖（纯 Vim 9.1+ 内建 job/json）；真实 agent preset 需用户自装对应 CLI（claude-agent-acp / pi-acp），mock preset 仅需 python3
- **兼容**：spike 的 `research/acp-spike/` 保持原样作为调研资料，不删除；正式插件命令前缀从 `Acp*` 改为 `Agent*`（spike 非交付物，不构成 breaking）
- **风险**：vim9script `import autoload` 的跨模块状态共享（job/session 句柄）需按踩坑清单规避 E117 等；CI 首跑可能暴露 Vim 9.1 与 9.2 的 vim9script 行为差异
