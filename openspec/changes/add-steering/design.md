# Design: add-steering

## Context

M4 后输入区/队列/模式齐备。steering 补上"轮次中改方向"的最后一块。三桥矩阵已实测（proposal 表格）：claude native（mid-turn injected 实测生效）、pi 服务端排队（-32601 + turnQueue 源码实证）、mock 待造。

## wire 契约（实测 2026-11-21）

```
claude: _session/steering {sessionId, prompt:[blocks]} →
  result: {outcome: "injected" | "startedNewTurn" | "promptRequired"(v2 opt-in, 本插件不启用)}
  - mid-turn → injected（实测：数数轮第 4s 注入停止指令 → 数数中止 → 输出 STEERED-OK）
  - idle 第一次 → startedNewTurn；随之第二轮（新轮进行中）再 steer → injected
  - 不支持时 → -32601
pi: 无该方法；busy 中 session/prompt → 桥自动入队
  （推 "Queued message (position N)" agent_message_chunk +
   session_info_update._meta.piAcp.queueDepth/running）
```

## Goals / Non-Goals

**Goals**：三桥统一交互（`<M-CR>` 一个入口）；能力探测自动降级且会话内缓存；outcome 三值呈现；与 M4 队列交互矩阵明确。

**Non-Goals**：v2 `promptRequired` opt-in（不启用，行为按三值处理天然兼容）；pi 的 `/steering all|one-at-a-time` 模式切换（文本命令，用户可用 `/` 补全发）；取消轮次（session/cancel 是另一特性）。

## Decisions

### D1：能力状态机——session 模块内三态

```
var steer_mode = 'unknown'   # unknown | native | queued | none
initialize 响应 _meta.steering.supported==true（claude 实测有，归档流量 L1）→ 直接标 native（W4 免首探）
预设：preset.steering 显式给值（native/queued/none）则直接用（跳过探测）
SteerText() 分派：
  native → _session/steering（idle 也走——startedNewTurn 桥自起轮，实测已验；B3 决策②）
  queued → busy ? FirePrompt(session/prompt 桥端排) : SendPromptText
  none → 提示不支持
  unknown（首探）→ 发 _session/steering（记 id_steer）
    响应 result.outcome → 标 native + 呈现
    响应 -32601 → 标 queued + 本次内容自动经 FirePrompt/SendPromptText 重发 + 提示排队语义
    其他错误 → 错误呈现；连续 3 次非 -32601 失败 → 标 none + 提示可 preset 覆盖（W3）
Stop → steer_mode 回 unknown（进程级；load/new 不重置——能力属 agent，N2）
queued 路径 session/prompt 被 agent 拒 → 错误呈现 + 「该 agent 可能不支持排队」提示（W6 假阳性防护）
```

### D2：发送路径与队列交互矩阵

| 状态 | `<M-CR>` 行为 |
|---|---|
| 非 busy | 提示「空闲态直接发送」→ 走 SendPromptText（经 M4 组包：可带图） |
| busy + native | `_session/steering` 直发（带 id_steer 语义 id；不进 queue、不占 queue 名额） |
| busy + queued | FirePrompt 直发 session/prompt（**不入客户端 queue**——桥自己排；与 M4 的"busy→Enqueue"分流：steering 入口优先桥端排队，客户端 queue 仍服务普通 `<CR>`） |
| busy + unknown | 按 D1 首探 |

- steering 消息也经 M4 组包（text?+image）复用 AttachImage 槽——`<M-CR>` 与 `<CR>` 的组包一致
- busy 中 steer 的 queued 路径用 FirePrompt 直发：busy 已 true，不重复置位；其响应 stopReason 到达时 BusyClear 照常出队——**W2 防护**：queued steer 时若客户端队列非空，追加一行警告「客户端队列 N 条将与桥端排队交错发送」（pi FIFO 兜底顺序仍正确；跨桥假阳性由 W6 错误呈现防护）；README 写明交错后果
- 归档补充：claude initialize `_meta.claudeCode.promptQueueing:true`（桥也有队列能力）——M4 客户端队列与桥端队列的并存策略后续迭代评估，本 change 不动

### D3：UI——render 映射与提示

- `SetupWindow` 增：`nnoremap/inoremap <buffer> <M-CR> <ScriptCmd>agent_shell#render#SteerInput()<CR>`
- `render.SteerInput()`：复用 SendInput 的提取（空输入提示；`[` 防线同样适用）→ `session.SteerText(text)`
- 提示样式：`[STEER] ↪ 已注入当前轮次` / `[STEER] ↪ 已开启新轮次` / `[STEER] 排队语义：已交由 agent 服务端排队` / `[STEER] 空闲态：按普通消息发送`
- pi 的 `Queued message` agent_message_chunk 由既有渲染通道自然呈现（无需特判）
- **转向消息本地回显（B2）**：发出即 `render.Log('你·STEER', text)`——claude 实测不回推 user_message_chunk，客户端自渲染；样式 `[你·STEER] …` 与 `[STEER] ↪ …` outcome 行配对
- 空输入且无附件 → 复用 SendInput 空提示（N5）

### D4：presets 声明

`presets.Resolve` 透传 `steering` 字段（'native'/'queued'/'none'——none 则 `<M-CR>` 提示不支持并建议普通发送）；内置三 preset 不声明（走探测），README 示例展示自定义声明

### D5：mock 夹具

- `_session/steering`：MOCK_STEER=queued 时回 -32601（驱动降级路径）；MOCK_STEER=err 时回 -32000（W3 收敛测试）；默认回 `{outcome:'injected'}` 并：**若 self.pending（权限挂起轮）存在，先 self.pending=None 作废权限流**（B1：防孤儿 perm——客户端 stale 答复由 mock 静默丢弃，buffer 权限行被转向提示自然覆盖），再推 `agent_message_chunk("（收到转向）")` + 挂起轮次 `stopReason:'end_turn'`（模拟注入生效）
- pi 形状的 `Queued message` + queueDepth `_meta` 在 queued 模式的 prompt 路径推（可选，断言用第一段即可）

## Risks / Trade-offs

- [`_session/steering` 为桥扩展方法，非 ACP 标准] → 探测状态机天然容忍变形（unknown 重探）；协议升级只改 outcome 呈现
- [queued 路径的客户端/服务端双层排队混乱] → D2 矩阵文档化：steer 入口=桥端排，普通 CR=客户端排；pi 用户引导用 steer
- [busy 中 steer 的响应 id 与 prompt 响应混淆] → id_steer 语义 id 分派（M3 D7 顺序：语义 id 优先）
- [headless 测不了映射] → 映射归手动清单；断言走 `SteerText`/`SteerInput` 导出

## Migration Plan

纯增量。72 断言零改动预期回归。回滚 revert。

## Open Questions

无（v2 opt-in 不启用已定；cancel 独立立项已定）。
