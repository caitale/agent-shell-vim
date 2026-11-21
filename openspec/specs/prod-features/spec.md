# prod-features Specification

## Purpose
TBD - created by archiving change add-production-features. Update Purpose after archive.

## Requirements

### Requirement: 输入区补全

输入区 insert 模式下：键入 `@` 触发文件路径补全（基于 cwd 的递归文件匹配，呈现相对路径菜单，选择后插入路径）；行首键入 `/` 触发斜杠命令补全（数据源为 agent 推送的可用命令表，无命令数据时无菜单不报错）。补全菜单项按类型分组呈现，选择不破坏输入区其余内容。

#### Scenario: @文件补全

- **WHEN** 输入区 insert 模式键入 `@` 后继续输入路径片段
- **THEN** 弹出匹配 cwd 下文件的补全菜单，选择后插入该文件相对路径

#### Scenario: 斜杠命令补全

- **WHEN** 输入区行首键入 `/` 且 agent 已推送过命令表
- **THEN** 弹出命令补全菜单（名称+描述），选择后插入命令名

#### Scenario: 无命令数据降级

- **WHEN** 行首键入 `/` 但无命令表缓存（agent 未推送）
- **THEN** 无补全菜单，正常输入，不报错

### Requirement: prompt 队列

轮次进行中发送的 prompt 进入本地 FIFO 队列（容量上限可配置，默认 5；超限提示并拒绝入队）。轮次结束（stopReason 到达、错误、权限拒绝）后自动发送队首 prompt，直至队列清空。队列非空时聊天中呈现待发计数；用户可清空队列。

#### Scenario: busy 时入队

- **WHEN** 轮次进行中从输入区发送 prompt
- **THEN** 该 prompt 入队，聊天呈现待发计数，当前轮次不受影响

#### Scenario: 轮次结束自动依序发送

- **WHEN** 队列非空且当前轮次结束
- **THEN** 队首 prompt 自动作为下一轮次发出，计数递减

#### Scenario: 队列超限

- **WHEN** 队列已达上限再次入队
- **THEN** 拒绝入队并提示上限

#### Scenario: 清空队列

- **WHEN** 用户执行清空队列命令
- **THEN** 队列清空并提示清空数量

#### Scenario: 换会话时队列清空

- **WHEN** 队列非空时发生会话切换（load/new/Stop）
- **THEN** 队列清空并提示（排队 prompt 归属原会话，不串发到新会话）

### Requirement: 成本显示

插件累计 agent 推送的 token 用量（输入/输出分别累计，跨轮次求和），可随时查询：呈现本会话累计与最近一轮明细。累计在会话加载/新建时重置。

#### Scenario: 累计呈现

- **WHEN** agent 已推送若干轮 usage 后执行 `:AgentUsage`
- **THEN** 呈现累计输入/输出 token 与最近一轮明细

#### Scenario: 换会话重置

- **WHEN** session/load、AgentSessionNew 或 AgentStop 发生
- **THEN** 累计计数清零重新开始

#### Scenario: 无标准字段的总量降级

- **WHEN** agent 推送的 usage 无 inputTokens/outputTokens（仅有总量型字段如 used）
- **THEN** 以总量口径累计并呈现（标注总量），不虚构输入/输出拆分

### Requirement: 权限模式查看与切换

用户可查看 agent 支持的权限模式列表（含当前模式）并切换：切换发送 session/set_mode，成功后呈现确认；无效模式 ID 提示可选列表。同时可查看会话配置项（含模型当前值与可选项列表——只读展示）。

#### Scenario: 查看模式列表

- **WHEN** 执行 `:AgentMode`（无参数）
- **THEN** 呈现可用模式列表并标注当前模式

#### Scenario: 切换成功

- **WHEN** 执行 `:AgentMode plan`（plan 为有效模式）
- **THEN** 发送 session/set_mode，成功呈现确认

#### Scenario: 无效模式提示

- **WHEN** 执行 `:AgentMode bogus`
- **THEN** 提示无效并列出可选模式，不发送 RPC

#### Scenario: 配置查看（含模型）

- **WHEN** 执行 `:AgentConfig`
- **THEN** 呈现 configOptions：模式与模型的当前值及可选项（模型只读展示）

#### Scenario: 无模式数据降级

- **WHEN** agent 未在 session/new 提供 modes 数据
- **THEN** `:AgentMode` 提示当前 agent 未提供模式列表，不发送 RPC

### Requirement: 图片附件

用户可将本地图片指定为待发附件：插件读取文件校验（格式 png/jpg/webp、大小上限 2MB）后以 base64 编码挂到输入区待发队列，随下一次发送以 ACP image block 一并发出；发送后附件清空。无效路径/超限/格式错误分别提示。

#### Scenario: 挂附件并发送

- **WHEN** `:AgentImage /path/pic.png` 后从输入区发送文本
- **THEN** prompt 携带 [text, image] 双 block 发出，发送后附件清空

#### Scenario: 仅图片发送（空输入区）

- **WHEN** 挂附件后输入区为空直接发送
- **THEN** prompt 仅携带 image block 发出（空输入不再是拦截条件），发送后附件清空

#### Scenario: 超限拒绝

- **WHEN** 指定超过 2MB 的图片
- **THEN** 拒绝挂载并提示大小上限

#### Scenario: 格式不符

- **WHEN** 指定非 png/jpg/webp 文件
- **THEN** 拒绝并提示支持的格式
