# chat-ui Specification

## Purpose
TBD - created by archiving change add-chat-ui-baseline. Update Purpose after archive.

## Requirements

### Requirement: 聊天窗口布局

`:AgentOpen` 支持布局参数：`bottom`（水平分割，默认）与 `right`（右侧垂直分割）。重复调用不创建第二个窗口；聊天窗已开时聚焦。右侧布局的宽度与底部布局的高度可由用户配置覆盖。

#### Scenario: 底部布局（默认）

- **WHEN** 执行 `:AgentOpen`（无参数）
- **THEN** 聊天窗口以水平分割打开，buffer 显示聊天内容

#### Scenario: 右侧布局

- **WHEN** 执行 `:AgentOpen right`
- **THEN** 聊天窗口以右侧垂直分割打开，宽度可被用户配置覆盖

#### Scenario: 重复打开聚焦

- **WHEN** 聊天窗口已存在，再次执行 `:AgentOpen`
- **THEN** 不创建新窗口，光标聚焦到既有聊天窗口

### Requirement: 常驻输入区

聊天 buffer 尾部维护一条可见分隔线，分隔线之上为对话历史，之下为常驻输入区（可编辑、可多行）。在输入区按 `<CR>`（normal 与 insert 模式）将输入区内容发送：全部非空行保序合并（换行连接，仅去除首尾空白行），粘贴的中间空行保留。发送后输入区清空并保持分隔线与输入区位于 buffer 末尾。消息追加时输入区整体保持在最下方（新内容插入到分隔线之前）。历史区不强制锁定，但历史行以 `[` 开头受发送防线保护（以 `[` 开头的内容不会被当作输入发送），文档标注建议勿手改。

#### Scenario: 多行输入发送

- **WHEN** 用户在输入区写了三行文本后按 `<CR>`
- **THEN** 三行保序合并（换行连接）为一条 prompt 发送，输入区清空

#### Scenario: 历史区软防线

- **WHEN** 历史区某行以 `[` 开头且用户尝试从该行发送内容
- **THEN** 该内容不会被发送（防线拒绝），输入区发送路径不受影响

#### Scenario: 流式消息不打断输入区

- **WHEN** agent 流式回复期间用户正在输入区编辑
- **THEN** 新消息插入到分隔线之前，输入区内容与光标位置保持不变

### Requirement: busy 状态指示

轮次进行期间聊天窗口状态行（局部 statusline）提供可见的进行中指示：prompt 发出后指示启动（旋转字符帧），stopReason 或错误到达后指示停止。指示不写入 buffer 内容（停止后 buffer 中无指示残留行）；窗口不显示（headless）时指示不启动但轮次状态仍可查询。

#### Scenario: 轮次进行中可见

- **WHEN** prompt 已发出且尚未收到 stopReason，且聊天 buffer 有窗口显示
- **THEN** 该窗口状态行呈现进行中指示

#### Scenario: 轮次结束清除

- **WHEN** 收到 stopReason（或权限拒绝、错误）
- **THEN** 进行中指示消失，buffer 中不残留指示行

### Requirement: tool_call 折叠块

每个工具调用渲染为自包含折叠块：折叠态显示单行摘要（工具标题与状态），展开态含完整工具输出。折叠以 Vim 内建 marker 机制实现（窗口局部 foldmethod=marker，自定义 foldmarker 避免与内容冲突）；窗口无显示或折叠不可用时，渲染退化为普通多行文本（marker 文本无 fold 语义即普通文本），不报错。

#### Scenario: 折叠块结构

- **WHEN** 收到带 content 的 tool_call 更新且聊天窗口以 marker 折叠呈现
- **THEN** 折叠态显示单行摘要（标题+状态），展开可见完整工具输出

#### Scenario: 折叠不可用降级

- **WHEN** 聊天 buffer 无窗口显示（headless）或折叠不可用
- **THEN** 工具调用以普通多行文本呈现（含 marker 文本行），无报错
