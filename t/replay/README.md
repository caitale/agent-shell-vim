# t/replay/ — traffic 回放夹具

真实 agent 会话的 JSONL 样本，作为零 token 回归资产（`g:agent_shell_debug` 录制）。

## 样本清单

| 文件 | 来源 | 场景 | 统计 |
|---|---|---|---|
| `claude-full.jsonl` | claude-agent-acp（真实） | 完整轮次：initialize/new/prompt/回显/chunk/usage×3/stopReason | 14 replay / 3 skip / 0 bad |
| `pi-queued.jsonl` | pi-acp（真实，节选） | 服务端排队：mid-turn prompt 被桥排队、两轮依序完成 | 11 replay / 0 skip / 0 bad |

## 录制新样本

1. 设 `let g:agent_shell_debug = '/tmp/my_dump.jsonl'`
2. 正常使用（或脚本驱动）跑完目标场景——**完整轮次**（到 stopReason）
3. 脱敏检查：`grep -iE 'sk-|api[_-]?key|authorization|bearer' /tmp/my_dump.jsonl`——命中则检查是否为实值（`totalTokens` 等字段名 / 模型描述文本不算）
4. 头部加 `#` 注释行：来源 agent、录制日期、场景说明、脱敏声明
5. 入库本目录；在 `t/test_protocol_session.vim` 组I 补对应锚点断言

## 待录场景（backlog）

- **edit 六事件**（tool_call + tool_call_update 的 diff content）→ 锚点：`«as»` 折叠块渲染 + diff 队列条目
- **steering 响应**（`_session/steering` 的 injected/startedNewTurn）→ 锚点：`[STEER]` outcome 行
- **带 inputTokens/outputTokens 拆分的 usage_update** → 锚点：`累计 in=` 标准口径行
- **request_permission 流量** → 锚点：权限请求行渲染

## 注意

- 样本行序即因果序；非连续节选须保持因果序（见 pi-queued 头注释）
- 回放器方向判别白名单（`autoload/agent_shell/replay.vim` CLIENT_METHODS）随协议面扩大同步——未知 method+id 会落 bad 并在统计行提示
- initialize/new 响应含握手副作用（Register/ParseModes），节选时按需排除
