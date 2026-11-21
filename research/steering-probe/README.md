# steering 三桥探测存档（2026-11-21）

原始 JSONL 流量：steer_midturn.jsonl（claude mid-turn 注入实验）、steer_pi.jsonl（pi 排队实验）。

## 实验设计

1. **claude mid-turn**：慢轮次（数 1–50）第 4 秒发 `_session/steering`「立即停止，回复 STEERED-OK」
   - 结果：`outcome:"injected"`；数数中止（未到 50）；最终输出 STEERED-OK
2. **pi mid-turn**：慢轮次第 4 秒直接发 `session/prompt`（pi 无 steering 方法）
   - 结果：桥自动入队（`Queued message (position N)` + `_meta.piAcp.queueDepth`）；两轮依序完成
3. **claude idle**：连续两次 steering
   - 第一次 `startedNewTurn`（桥自起轮）；第二次（新轮进行中）`injected`

## 结论（add-steering 的实证基础）

- claude：native 直发（mid-turn injected 实测生效）
- pi：-32601 → 降级为"服务端排队"语义（busy 中 session/prompt 桥自动排）
- outcome 三值全覆盖处理；`promptRequired` 为 v2 opt-in（不启用）
