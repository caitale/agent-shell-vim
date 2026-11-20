## ADDED Requirements

### Requirement: 会话列表

用户可请求 agent 的历史会话列表：列表项含标题、最后更新时间、工作目录与会话标识；在聊天 buffer 中以带序号的行渲染，序号供后续 load 选择。列表获取失败（agent 未启动或不支持）给出可理解提示，不中断当前会话。结果含分页游标时，剩余页继续获取并合并呈现。

#### Scenario: 列表渲染

- **WHEN** 执行 `:AgentSessionList` 且 agent 运行中、支持 session/list
- **THEN** 聊天 buffer 渲染带序号的会话列表（每项含标题/时间/目录）

#### Scenario: agent 未启动时提示

- **WHEN** 执行 `:AgentSessionList` 而 agent 未启动
- **THEN** 提示先启动 agent，不发送任何 RPC

#### Scenario: 空列表

- **WHEN** agent 返回空会话列表
- **THEN** 聊天 buffer 呈现"无历史会话"提示

#### Scenario: 分页合并

- **WHEN** session/list 响应含非空 nextCursor
- **THEN** 继续请求后续页并合并为单一列表呈现

### Requirement: 会话恢复加载

用户可从列表（或本地登记表）选择一个会话恢复：插件向当前 agent 发送 session/load（携带目标 sessionId 与其原始 cwd）；加载成功后当前会话标识替换为加载的会话，聊天 buffer 记录恢复来源（标题+sessionId），后续 prompt 在恢复的会话上下文中进行。加载失败（会话不存在/agent 拒绝）呈现错误并保持当前会话不变。

#### Scenario: 从列表加载

- **WHEN** 列表已渲染，执行 `:AgentSessionLoad 2`
- **THEN** 发送 session/load（第 2 项的 sessionId 与 cwd），成功后当前 sessionId 更新且聊天 buffer 记录恢复来源

#### Scenario: 加载失败保持现状

- **WHEN** session/load 返回错误（如会话 ID 不存在）
- **THEN** 错误呈现，当前会话与后续可用性不变

#### Scenario: 序号无效提示

- **WHEN** 执行 `:AgentSessionLoad 99`（列表无此项）
- **THEN** 提示序号无效并列出可选范围，不发送 RPC

#### Scenario: 带参加载时 agent 未启动

- **WHEN** 执行 `:AgentSessionLoad 2` 而 agent 未启动
- **THEN** 提示先启动 agent（或使用无参形式自动恢复），不发送 RPC

#### Scenario: 轮次进行中拒绝切换

- **WHEN** 轮次进行中（busy）执行 load/list/new 任一命令
- **THEN** 提示轮次进行中，不发送 RPC

### Requirement: 新建与当前会话查询

用户可在同一 agent 进程内新建会话（切换到全新上下文）并随时查询当前会话信息。新建成功后聊天 buffer 分隔标记新会话开始，旧会话不销毁（仍可再次 load 恢复）。查询呈现 preset、sessionId、标题（若 agent 提供）。

#### Scenario: 新建会话

- **WHEN** 执行 `:AgentSessionNew`
- **THEN** 发送 session/new，成功后 sessionId 更新，聊天 buffer 标记新会话开始

#### Scenario: 查询当前会话

- **WHEN** 执行 `:AgentSessionCurrent`
- **THEN** 呈现当前 preset 与 sessionId

### Requirement: 本地会话登记与跨启动恢复

插件将成功的会话（新建/加载/正常握手）登记到本地（preset、sessionId、标题、时间），持久化存储。`:AgentSessionLoad` 无参数时从登记表取最近一条：若 agent 未运行则按登记的 preset 自动启动后加载。登记表条目失效（load 失败）时提示并可从登记表清除该条目。

#### Scenario: 登记持久化

- **WHEN** 会话建立成功后退出 Vim 再进入
- **THEN** 登记表仍含该会话条目

#### Scenario: 无参恢复含自动启动

- **WHEN** agent 未运行，执行 `:AgentSessionLoad`（登记表非空）
- **THEN** 按登记 preset 自动启动 agent 并 load 最近会话

#### Scenario: 失效条目降级

- **WHEN** 无参 load 的目标会话已失效（agent 返回错误）
- **THEN** 提示失效并从登记表清除该条目，不自动尝试下一条

#### Scenario: 空登记表提示

- **WHEN** 执行 `:AgentSessionLoad`（无参数）且登记表为空
- **THEN** 提示无可恢复会话并引导使用 `:AgentSessionList`，不启动 agent、不发送 RPC

#### Scenario: 自动启动失败

- **WHEN** 无参 load 触发自动启动，但登记的 preset 已不存在（或 agent 启动失败）
- **THEN** 错误呈现、不发送 session/load，提示可清除该登记条目
