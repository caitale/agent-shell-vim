# acp-transport

Delta: ADDED（新 capability，随 add-plugin-skeleton 引入）

## ADDED Requirements

### Requirement: Agent 进程生命周期

插件能以用户指定的 agent 启动命令（list 形式）spawn 子进程，并通过 stdio 与之通信。重复启动被拒绝并提示；停止时正确终止子进程；未启动时发送消息给出可理解的错误提示而非静默失败。

#### Scenario: 启动 mock agent

- **WHEN** 执行 `:AgentStart mock`
- **THEN** mock agent 子进程启动并保持存活，initialize 请求发出且得到响应（会话级结果的验收归 acp-session）

#### Scenario: 重复启动被拒绝

- **WHEN** agent 已在运行，再次执行 `:AgentStart <preset>`
- **THEN** 不产生第二个子进程，聊天 buffer 提示已在运行

#### Scenario: 停止

- **WHEN** 执行 `:AgentStop`
- **THEN** 子进程被终止，后续发送提示 agent 未启动

### Requirement: JSON-RPC stdio 分帧

与 agent 的每条消息为单行 JSON（换行分隔）。客户端发往 agent 的每个请求携带自增 id；来自 agent 的响应能按 id 关联到对应请求类别（握手 / 建会话 / 轮次结束）；无法解析的行被安全忽略，不中断后续处理。

#### Scenario: 请求 id 关联

- **WHEN** 依次发出 initialize、session/new、session/prompt 请求
- **THEN** 各响应按其对应请求正确归类处理：session/new 响应提取 sessionId，prompt 响应呈现 stopReason，握手响应仅确认协议版本接受

#### Scenario: 噪音行容错

- **WHEN** agent 输出包含空行或非 JSON 行
- **THEN** 该行被忽略，不抛错、不影响后续消息处理

### Requirement: stderr 降噪

agent 侧 stderr 默认不进入聊天 buffer（真实适配器会向 stderr 输出大量诊断日志）；提供显式开关让用户需要时可查看全部 stderr 输出。

#### Scenario: 默认静默

- **WHEN** agent 向 stderr 写入诊断日志
- **THEN** 聊天 buffer 不出现这些内容

#### Scenario: 显式开启诊断

- **WHEN** 用户设置 verbose 开关后 agent 写 stderr
- **THEN** stderr 内容出现在聊天 buffer 供排障

### Requirement: 原始流量落盘（调试）

提供调试开关，把 agent 双向的每行原始 JSON 追加写入用户指定路径的文件。该文件用于协议排障与后续 traffic 回放，默认关闭。

#### Scenario: 开启调试落盘

- **WHEN** 用户设置调试路径后与 agent 交互
- **THEN** 指定文件按行累积原始 JSON 消息，内容与线上流量一致
