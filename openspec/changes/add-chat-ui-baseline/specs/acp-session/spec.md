## MODIFIED Requirements

### Requirement: 轮次与 stopReason 语义

每次用户 prompt 触发一个轮次；轮次结束的语义状态（进行中 / 已结束 / 结束原因）对用户可见：轮次期间呈现进行中指示（见 chat-ui「busy 状态指示」），轮次结束时 prompt 响应的 stopReason 呈现给用户（end_turn 正常结束 / refusal 权限拒绝等）。轮次期间到达的 session/update 事件流式渲染，不等待轮次结束才显示。

#### Scenario: 正常轮次

- **WHEN** 发送 prompt 且 agent 正常完成
- **THEN** 流式内容逐步呈现且轮次期间有进行中指示，最终呈现 stopReason=end_turn 且指示移除

#### Scenario: 拒绝轮次

- **WHEN** 权限请求被用户拒绝
- **THEN** agent 中止任务，呈现 stopReason=refusal，进行中指示移除

#### Scenario: 轮次错误终止可见

- **WHEN** prompt 请求返回 JSON-RPC 错误（agent 异常等）
- **THEN** 错误呈现给用户，进行中指示移除，不遗留"进行中"的假状态
