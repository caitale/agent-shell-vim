# Proposal

## Why

M1 后用户已能在聊天界面对话并指挥 agent 干活，但 agent 的文件改动**直接落盘、不可见**——用户只能事后 `git diff` 检查，或盲目信任。两个标杆（agent-shell / agentic.nvim）都把"改动审查"作为核心护城河：agent 改了什么、以 diff 呈现、接受或拒绝。M2 补上这块信任缺口，是日常使用安全性的分水岭。

## What Changes

- **diff 数据捕获**：session/render 捕获 tool_call 更新中的结构化 diff 信息（geohar 桥对 edit 类工具输出 oldText/newText，含工具标题中的文件路径），存为待审查项（pending diff：文件路径 + 旧文本 + 新文本）
- **审查入口**：折叠块上按 `d`（新 buffer-local 映射）对该 tool_call 打开 vimdiff 视图：左侧插件生成的旧版临时 buffer，右侧当前实际文件；`:AgentDiffAccept` / `:AgentDiffReject`（及 vimdiff 窗口内映射 `]a`/`]r` 便捷键）执行接受/拒绝
- **接受语义**：保持当前文件内容不变（agent 已写入），仅清除 pending 状态并记录；**拒绝语义：文件当前内容与 newText 一致时恢复为 oldText**（写回），并记录
- **自动弹出**（可配 `g:agent_shell_diff_auto`，默认关）：edit 条目 completed 且有窗口时自动打开 vimdiff 审查（无窗口不弹不炸）
- **多文件支持**：pending 队列按 tool_call 顺序排列，审查完自动跳到下一个未审查项；聊天 buffer 内 TOOL 折叠块状态行追加审查标记（`✓已接受` / `✗已拒绝` / `待审查`）
- mock_agent.py 扩展：edit 类 tool_call 带 oldText/newText 结构化 content（测试夹具对齐真实桥行为）

## Capabilities

**New Capabilities**：

- `diff-review`：结构化 diff 的捕获、vimdiff 审查、接受/拒绝语义、pending 队列与状态标记（全部可观察行为）

**Modified Capabilities**：

- 无（chat-ui 的 TOOL 折叠块呈现追加审查标记属渲染细节扩展，不改其 requirement 语义；权限审批流程不变）

## Impact

- **代码**：新增 `autoload/agent_shell/diff.vim`（捕获/队列/vimdiff 编排/接受拒绝）；render.vim（`d` 映射 + 状态标记）；session.vim（tool_call 转发 diff 模块）；plugin 入口两命令
- **依赖**：无新增（vimdiff/diffbuf 均内建）
- **测试**：mock 夹具扩展 + 新断言（捕获/恢复语义/队列/标记）；headless 下 vimdiff 窗口操作受限——接受/拒绝走命令路径断言，窗口视觉项归手动清单
- **风险**：oldText 与实际文件不一致（agent 落盘失败或并发修改）时拒绝路径的写回需校验（不一致则警告并跳过写回）；拒绝恢复与 undo 树的交互（直接 writefile 而非 buffer 编辑，绕开 undo）
