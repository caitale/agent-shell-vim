# acp-session Specification

## Purpose
TBD - created by archiving change add-plugin-skeleton. Update Purpose after archive.

## Requirements

### Requirement: ACP 握手序列

启动 agent 后客户端自动完成 initialize → session/new 握手：initialize 声明客户端能力（无 fs 读写、无 terminal）；session/new 携带 cwd 与空的 mcpServers 数组（真实适配器 zod 校验必需）。握手各阶段的结果反映在聊天 buffer。

#### Scenario: 完整握手

- **WHEN** 执行 `:AgentStart <preset>` 且 agent 可用
- **THEN** 自动发出 initialize 与 session/new，会话建立后 sessionId 被保存并呈现给用户

#### Scenario: session/new 被拒绝

- **WHEN** agent 对 session/new 返回错误（如缺 mcpServers 被校验拒绝）
- **THEN** 错误呈现给用户，不进入可用会话状态

### Requirement: 轮次与 stopReason 语义

每次用户 prompt 触发一个轮次；轮次结束时 prompt 响应的 stopReason 呈现给用户（end_turn 正常结束 / refusal 权限拒绝等）。轮次期间到达的 session/update 事件流式渲染，不等待轮次结束才显示。

#### Scenario: 正常轮次

- **WHEN** 发送 prompt 且 agent 正常完成
- **THEN** 流式内容逐步呈现，最终呈现 stopReason=end_turn

#### Scenario: 拒绝轮次

- **WHEN** 权限请求被用户拒绝
- **THEN** agent 中止任务，呈现 stopReason=refusal

### Requirement: wire format 判别

session/update 事件的解析以 `params.update.sessionUpdate` 为判别字段（对拍真实适配器实证）；未知 update 类型不报错、静默跳过或以提示呈现，保证对新 agent 的前向兼容。

#### Scenario: 已知类型渲染

- **WHEN** 收到 user_message_chunk / agent_message_chunk / tool_call / plan 类型的 update
- **THEN** 各自在聊天 buffer 呈现对应内容

#### Scenario: 未知类型容错

- **WHEN** 收到插件未实现渲染的 update 类型（即内置渲染表之外的 sessionUpdate 值，如协议未来新增的 `future_tool_call_update`）
- **THEN** 不抛错、不中断，轮次继续

### Requirement: 权限请求审批

agent 反向发起 session/request_permission 时，插件呈现请求与选项，用户可用两个命令（或 buffer 内按键）答复允许/拒绝；无挂起权限时答复命令给出提示且不发消息。同一时刻只跟踪一个挂起的权限请求。

#### Scenario: 允许

- **WHEN** 权限请求到达后用户答复允许
- **THEN** 对应 optionId 的选择被回发，agent 继续执行，聊天 buffer 记录答复

#### Scenario: 拒绝

- **WHEN** 用户答复拒绝
- **THEN** 拒绝选项被回发，轮次以 refusal 结束

#### Scenario: 无挂起请求时误触

- **WHEN** 没有挂起的权限请求，用户执行答复命令
- **THEN** 提示当前无挂起请求，不向 agent 发送任何消息
