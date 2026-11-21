# steering Specification

## Purpose
TBD - created by archiving change add-steering. Update Purpose after archive.

## Requirements

### Requirement: 中途转向发送

轮次进行中用户可发送转向消息（不取消当前轮次）：输入区 `<M-CR>`（normal 与 insert 模式）或 `:AgentSteer <text>` 将内容经 steering 通道发出。转向消息不进入客户端队列（区别于普通 prompt 的排队语义）。空闲（非 busy）时发送转向消息走普通 prompt 路径并提示。

#### Scenario: 轮次中转向（native）

- **WHEN** 轮次进行中按 `<M-CR>` 发送转向消息且 agent 支持 steering
- **THEN** 消息经 `_session/steering` 发出，聊天呈现转向已发出与 agent 返回的结果（injected/startedNewTurn）

#### Scenario: 空闲时转向（native 走 steering 通道）

- **WHEN** 非 busy 状态且能力为 native（已知或探测成功）时按 `<M-CR>` 发送
- **THEN** 仍经 `_session/steering` 发出（桥按 startedNewTurn 语义自起轮次——实测已验证）

#### Scenario: 空闲时首探

- **WHEN** 非 busy 状态且能力未知时按 `<M-CR>` 发送
- **THEN** 发送 `_session/steering` 探测（探测成功即按 native 流程呈现 outcome；-32601 则降级为 queued 并按排队语义重发本次内容）

#### Scenario: 空闲时排队语义

- **WHEN** 非 busy 状态且能力为 queued 时按 `<M-CR>` 发送
- **THEN** 内容按普通 prompt 发送并提示

#### Scenario: 转向不排队

- **WHEN** 客户端队列非空且轮次进行中发送转向消息
- **THEN** 转向消息立即直发（不经队列），队列内容与顺序不变

#### Scenario: 转向消息本地回显

- **WHEN** 转向消息经 native 路径（`_session/steering`）发出
- **THEN** 聊天以可区分样式本地回显内容（`[你·STEER]`——claude 实测不回推 user_message_chunk，客户端自渲染；queued 路径由 agent 回推 user_message_chunk，不做本地回显防双显）

#### Scenario: 空输入转向拒绝

- **WHEN** 输入区为空且无挂起附件时按转向键
- **THEN** 提示输入区为空，不发送

### Requirement: steering 能力探测与降级

插件按 agent 维护 steering 能力标记（native / queued / none）：initialize 响应 `_meta` 声明 steering 支持时直接标记 native（免首探）；否则默认未知，首次转向时发送 `_session/steering`——收到 `-32601` 即标记 queued 并自动改走 `session/prompt`（服务端排队语义）。标记缓存到 agent 进程结束。用户可通过 preset 配置显式声明（`steering` 字段）覆盖探测。queued 模式下 busy 中发送走 `session/prompt`，聊天提示已交由 agent 排队。

#### Scenario: 方法不支持自动降级

- **WHEN** agent 对 `_session/steering` 返回 -32601（方法不存在）
- **THEN** 该 agent 标记为 queued，本次转向内容自动经 `session/prompt` 重发，提示排队语义

#### Scenario: preset 显式声明

- **WHEN** preset 配置 `steering: 'queued'`
- **THEN** 跳过探测，直接走排队路径

#### Scenario: 标记进程内缓存

- **WHEN** 某 agent 进程曾探测为 queued
- **THEN** 同一进程内后续转向不再尝试 `_session/steering`（能力属 agent 不属 ACP 会话；load/new 不重置，Stop/重启重置）

#### Scenario: 排队假阳性防护

- **WHEN** queued 模式下 busy 中经 session/prompt 发送被 agent 拒绝（第三方桥无服务端排队能力）
- **THEN** 错误呈现并提示该 agent 可能不支持排队（提示用户检查 preset 声明）

#### Scenario: 连续探测失败收敛

- **WHEN** steering 探测连续 3 次非 -32601 错误
- **THEN** 标记为 none 并提示（可用 preset 显式声明覆盖）

#### Scenario: preset 声明 none

- **WHEN** preset 配置 `steering: 'none'` 时按转向键（无论 busy 与否）
- **THEN** 提示该 agent 不支持转向，建议普通发送，不发送任何消息

### Requirement: steering 结果呈现

steering 响应的 outcome 呈现给用户：injected（已注入当前轮次）/ startedNewTurn（已开启新轮次）以可区分的样式标记；非预期响应（错误/未知 outcome）呈现原文并保持当前会话可用。queued 模式下 agent 推送的排队确认消息（如 Queued message 提示）正常渲染。

#### Scenario: injected 呈现

- **WHEN** steering 响应 outcome=injected
- **THEN** 聊天呈现转向已注入当前轮次

#### Scenario: startedNewTurn 呈现

- **WHEN** steering 响应 outcome=startedNewTurn
- **THEN** 聊天呈现已开启新轮次

#### Scenario: 错误不破坏会话

- **WHEN** steering 响应为错误（非 -32601 的其他错误）
- **THEN** 错误呈现，当前轮次与会话状态不受影响
