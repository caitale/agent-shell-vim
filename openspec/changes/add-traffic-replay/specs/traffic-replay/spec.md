# traffic-replay Specification

## Purpose

把 `g:agent_shell_debug` 落盘的真实会话 JSONL 变成零 token、可进 CI 的回归夹具：回放驱动全插件解析链（session/render/diff/sessions），以关键事件锚点断言协议解析不回归。

## ADDED Requirements

### Requirement: JSONL 回放引擎

回放模块加载 dump 文件，按方向判别逐条分发，agent→client 方向的消息驱动完整解析链，全程零进程、零 RPC。

#### Scenario: 方向判别三规则

- **WHEN** 回放器读取一行 JSONL
- **THEN** 按 shape 判别：`method+id` 且 method ∈ 客户端方法白名单 → 跳过（client 请求）；`method` 无 id → 回放（agent 通知）；`id+result/error` → 回放（agent 响应）；`method+id` 且 method = `session/request_permission` → 回放（服务端请求）；`method+id` 且 method 不在白名单 → 计入 bad（提示同步白名单——协议面扩大防静默漏放）

#### Scenario: 注释头跳过

- **WHEN** 文件行以 `#` 开头（来源标注注释）
- **THEN** 跳过不解析

#### Scenario: 坏行降级

- **WHEN** 某行 JSON 解析失败
- **THEN** 计数并跳过（结果含 bad 行数），不中断回放

#### Scenario: 回放统计返回

- **WHEN** 回放完成
- **THEN** 返回统计 dict（replayed/skipped_client/bad），断言与 `:AgentReplay` 呈现共用

### Requirement: 关键事件锚点断言

回放不是"不炸就好"——每个场景样本配至少一条锚点断言，验证解析链的真实产出。

#### Scenario: claude 全链路样本锚点

- **WHEN** 回放 claude 全链路样本（initialize/new/prompt/回显/chunk/usage_update×3/stopReason——2026-11-21 重录，17 行）
- **THEN** 回放新增区出现：轮次结束行（stopReason=end_turn）、agent 回复渲染（[AI] 行且含 pong）、回放统计行（replayed=14）；且回放后 `:AgentUsage` 呈现标准口径累计行（in/out，来自样本的 inputTokens/outputTokens）

#### Scenario: diff 与 steering 锚点（待样本）

- **WHEN** 尚无含 edit 六事件或 steering 响应的入库样本（当前两份样本均无此流量）
- **THEN** 该两锚点暂不设自动断言；样本录制指南（t/replay/README.md）列出为待录场景，入库时同步补锚点

#### Scenario: diff 解析锚点

- **WHEN** 回放含 edit 六事件的流量（tool_call_update 的 diff content）
- **THEN** 折叠块渲染（`«as»` marker）且 diff 队列出现对应条目（path 含被改文件）

#### Scenario: steering 锚点

- **WHEN** 回放含 `_session/steering` injected 响应的流量
- **THEN** 聊天出现 `[STEER]` outcome 行（已注入当前轮次）

### Requirement: 真实流量样本入库

样本文件是 git 内的回归资产，来源可追溯、再生有指南。

#### Scenario: 样本入库与标注

- **WHEN** 样本文件放入 `t/replay/`
- **THEN** 文件头含 `#` 注释行标注来源 agent、录制日期、场景说明；回放器跳过注释行

#### Scenario: 样本再生指南存在

- **WHEN** 开发者需要录新流量
- **THEN** `t/replay/README.md` 提供录制步骤（设 `g:agent_shell_debug` → 跑场景 → 检查脱敏 → 入库）

### Requirement: 回放命令

`:AgentReplay <file>` 作为手动排障与验收入口。

#### Scenario: 命令回放与统计呈现

- **WHEN** 执行 `:AgentReplay t/replay/claude-full.jsonl`
- **THEN** 回放执行并在聊天 buffer 呈现统计行（replayed=N skipped=M bad=K）

#### Scenario: 文件不存在提示

- **WHEN** 指定文件不存在
- **THEN** 提示文件不存在，不报错不崩溃
