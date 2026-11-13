# Proposal

## Why

M0 交付了可用的协议内核（14 断言 + 双真实 agent 冒烟全绿），但聊天体验仍是 spike 形态的"写一行按 CR"：窗口固定水平分割、无消息类型高亮、无进行中状态指示、工具调用长输出刷屏、输入无常驻区。M1 把它升级为可日常使用的聊天界面——这是两个竞品标杆（agent-shell / agentic.nvim）共有的最小 UI 核心，也是 M2 diff 审查的交互基础。

## What Changes

- **窗口布局**：`:AgentOpen [right|bottom]`（默认 bottom 保持现状；right 为右侧垂直分割），聊天窗宽/高可配（`g:agent_shell_layout`）
- **常驻输入区**：聊天 buffer 尾部分隔线之后为可编辑输入区，多行输入，输入模式 `<CR>` 发送（发送区全部非空行合并，保序 join、仅去首尾空行），发送后清空输入区并重新渲染分隔线。历史区不强制锁定（软防线：历史行以 `[` 开头受发送防线保护，文档标注勿手改；锁定升级留 M2 评估）
- **消息类型高亮**：syntax region 按 `[AI]/[你]/[TOOL]/[PLAN]/[PERM]/[ERR]/[USE]` 等前缀着色（默认色板可关闭 `g:agent_shell_highlight = 0`）
- **busy 状态指示**：轮次进行中在聊天窗口状态行（局部 statusline）显示旋转指示（timer 驱动字符帧，窗口无显示时不启动），buffer 内容无指示行、轮次结束零残留；`session/prompt` 发出时启动，stopReason/error 到达时停止
- **折叠降级**：每个 tool_call 渲染为带自定义 marker 的折叠块（窗口局部 foldmethod=marker），折叠态显示单行摘要（标题+状态），展开看完整 content；marker 与用户内容冲突时可配置
- **BREAKING**：`render.Open()` 的 `<CR>` 从"发送当前行"改为"发送输入区全部内容"（含 insert 模式映射）；`SendCurrentLine` 移除

## Capabilities

**New Capabilities**：

- `chat-ui`：聊天界面的窗口布局、常驻输入区、busy 指示（可观察行为：布局参数、输入发送语义、状态可见性）

**Modified Capabilities**：

- `acp-session`：**MODIFIED**「轮次与 stopReason 语义」——增加轮次起止的状态可见性要求（busy 指示的启停时机绑定 prompt 发出与 stopReason/error 到达，属 spec 级行为变化）
- 注：消息高亮与折叠是纯渲染层呈现细节（render 的既有"呈现"义务的具体化），不改变 acp-transport/acp-session 的需求语义，不另立 delta——但 tool_call 折叠块内容完整性在 chat-ui 中以新 requirement 覆盖

## Impact

- **代码**：`autoload/agent_shell/render.vim`（主要改动：输入区/高亮/busy/折叠）、`session.vim`（busy 启停钩子）、`plugin/agent-shell.vim`（`:AgentOpen` 参数、新配置项）
- **依赖**：无新增（syntax/fold/timer 全部 Vim 内建）
- **测试**：现有 14 断言需适配（chat buffer 增加分隔线与折叠 marker，行数锚点逻辑要跳过结构行）；新增输入区/busy/折叠断言
- **风险**：headless（-es）下 timer 与 modifiable 锁定行为需验证；折叠 marker 与用户 fold 配置冲突时降级为不折叠
