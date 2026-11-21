# Proposal

## Why

轮次进行中用户只能干等或整个取消——发现方向错了无法中途纠偏。steering（中途转向）是 Emacs agent-shell 的独有特性、Neovim 竞品全部缺失，是 M5 差异化的第一枪。与 M4 队列天然协同：steering 消息插队改方向，普通消息排队。

## 三桥验证矩阵（2026-11-21 实测，原始流量 research/steering-probe/：midturn/pi 排队/方法探测三份 JSONL）

| 桥 | `_session/steering` | mid-turn 实效 | 结论 |
|---|---|---|---|
| **claude** | ✅ | ✅ **实测生效**：慢轮次（数 1–50）进行中第 4 秒 steering「立即停止，回复 STEERED-OK」→ `outcome:"injected"`、数数中止、最终输出 STEERED-OK、未到 50 | 主路径直发 |
| **pi** | ❌ `-32601`（方法探测流量 steer_pi_method_probe.jsonl） | ✅ **服务端排队**：mid-turn 再发 `session/prompt` → 桥自动入队（推 `Queued message (position N)` 消息 + `session_info_update._meta.piAcp.queueDepth`），第一轮 stopReason 后依序执行第二轮（实测两轮均完成、第二轮输出到达） | 降级为排队语义 |
| **mock** | 由本 change 定义 | — | 夹具实现 claude 形状 |

**claude steering 协议细节（实测 + 桥源码类型定义）**：
- 响应 outcome 三值：`"injected"`（注入进行中轮次）/ `"startedNewTurn"`（idle 时桥自行起轮）/ `"promptRequired"`（v2 opt-in 下无运行轮次，交还 Host 用标准 session/prompt 发——本插件不 opt-in，不会收到）
- idle 态连续两次 steering 实测：第一次 `startedNewTurn`、第二次（新轮已起）`injected`——outcome 处理必须三值全覆盖
- pi 的排队提示与 `_meta.piAcp.queueDepth` 可作为 UI 信号（M4 队列的服务端镜像）

## What Changes

- **`<M-CR>` steering 发送**：输入区（normal+insert）映射，读输入区内容（复用 SendInput 的提取逻辑）经 `_session/steering` 发送；不 busy 时提示并走普通发送（或直接发——design 决策）
- **能力探测**：per-preset 配置 `steering: 'native' | 'queued' | 'none'`（默认按方法探测缓存：首次 `_session/steering` 收到 -32601 即降级标记该 agent 为 queued 并改走 `session/prompt`——pi 语义；mock/claude 声明 native）
- **queued 模式行为**：busy 时 `<M-CR>` 直接发 `session/prompt`（桥自动排队），UI 提示「已交由 agent 排队」；呈现 pi 的 `Queued message` 回显与 queueDepth
- **outcome 呈现**：injected→「已注入当前轮次」；startedNewTurn→「已开启新轮次」；错误→按降级逻辑处理
- **M4 队列协同**：客户端队列存在时 steering 优先级高于队首（steering 直发不排队；队列出队时机不变）——design 明确交互矩阵
- **mock 夹具**：实现 `_session/steering`（native 形状：busy 时 injected + 立即完成当前轮 stopReason=steered？——夹具从简：injected + 中止当前计数轮）与排队路径（MOCK_STEER=queued 模拟 pi 语义）
- **BREAKING**：无

## Capabilities

**New**：`steering`——中途转向的发送、能力探测与降级、outcome 呈现、与客户端队列的交互（全部可观察行为）

**Modified**：无（chat-ui 输入区语义不变——`<M-CR>` 是新增映射；prod-features 队列 requirement 不动——steering 不经队列是新增路径的行为定义，在本 capability 内声明）

## Impact

- **代码**：session.vim（steering 发送/outcome 处理/能力探测缓存）；render.vim（`<M-CR>` 映射 + 提示）；presets.vim（preset 可配 steering 声明）；plugin 命令 `:AgentSteer [text]`
- **测试**：mock 夹具两模式；断言（native 注入/降级探测缓存/queued 提示/outcome 三值）；真实冒烟：claude mid-turn steering（复刻本 proposal 的数数实验）、pi 排队
- **风险**：`_session/steering` 是下划线扩展方法（非 ACP 标准）——桥升级可能变形；探测缓存按会话重置
