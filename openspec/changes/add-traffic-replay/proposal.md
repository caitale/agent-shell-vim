# Proposal: add-traffic-replay — traffic 回放测试基建

## Why

M0–M5-a 的回归防线是"mock 夹具 + 89 断言"——mock 是我们按 wire 契约**手写**的模型，契约本身若被误读（如 M2 的 `tool_call_update` 事件、M5 的 `_meta.steering`），mock 会与误读同构，测试永远绿。真实 agent 的冒烟测试（claude/pi）能覆盖这一点，但**耗 token、需人工触发、不进 CI**——每次协议解析改动后跑一遍既慢又贵。

`g:agent_shell_debug`（M0 起）已把真实会话的**双向原始 JSONL** 落盘。这些流量是 agent 真实行为的最终事实——把它们变成可回放的测试夹具，就得到一条零 token、可进 CI 的"真实流量回归"通道。

## What Changes

- 新模块 `autoload/agent_shell/replay.vim`：加载 JSONL → 方向判别 → 逐条喂 `session.Dispatch`（agent→client 方向）驱动全插件解析链（session/render/diff/sessions），**不启动任何进程、不发任何 RPC**
- 方向判别规则（实证自 /tmp/smoke_debug.jsonl 与 steering 探测流量）：`method+id` ∈ 白名单（initialize/session/new/prompt/load/list/set_mode/_session/steering…）→ client 请求（跳过）；`method` 无 id → agent 通知（回放）；`id+result/error` → agent 响应（回放）。**服务端请求**（`session/request_permission` 带 id+method）→ agent→client 方向（回放——Dispatch 已有 HandlePermission 分支）。
- 断言按**关键事件锚点**编写（如 "tool_call_update 的 diff content 必须渲染出 `«as»` 折叠块"、"steering 注入必须出现 `[STEER]` outcome 行"）——防"回放不炸"式空转
- 真实流量样本入库：`t/replay/<scenario>.jsonl`（claude 一份全链路、pi 一份排队流）——来源与录制日期在文件头注释行（`#` 前缀，回放时跳过）标注，git 可追溯
- `:AgentReplay <file>` 命令：手动回放任意 dump 文件（排障工具，同时是本 change 的验收路径）
- 夹具再生的说明文档：`t/replay/README.md`（如何用 `g:agent_shell_debug` 录新流量、如何挑选场景）

## 两桥流量样本能力对照（实测，2026-11-21；入库 claude 样本已重录为 17 行完整轮次版——旧 8 行为半链路残片弃用）

| 流量特征 | claude（/tmp/replay_claude_full.jsonl 重录版） | pi（research/steering-probe/steer_pi.jsonl） |
|---|---|---|
| 方向判别 | 形状规则成立（8 行全分类正确） | 成立 |
| 服务端请求 | `_auth/status_update` 为通知；暂无 request_permission 样本 | 无 |
| 会话响应形状 | session/new 带完整 modes/configOptions | 带基本字段 |

## Out of Scope

- 回放中客户端请求的**响应构造**（把 client 请求也"回答"掉做全双工仿真）——单方向回放已覆盖解析层，双工仿真留给未来
- 流量脱敏（token/路径）——入库样本为手动实验流量，不含密钥；录制指南提醒检查
- 定时/压力回放（按原始时间戳重放节奏）

## Modified

无。回放是新增的旁路通道（Dispatch 缝隙 export 化不改变既有行为；`session/request_permission` 的 Dispatch 分支 M0 即有）。
