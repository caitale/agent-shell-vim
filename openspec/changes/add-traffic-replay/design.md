# Design: add-traffic-replay

## Context

- 89 断言 mock 回归绿，但 mock 与 wire 契约误读同构的风险始终在（M2 tool_call_update、M5 _meta.steering 两度实证）。真实流量是唯一不受我们解读污染的事实源。
- debug 落盘（protocol.vim DebugDump）双向混写、无方向标记。样本实测：方向可按 shape 判别，但有两个坑——服务端请求（request_permission 带 id+method）不能误判为 client 请求；坏行（agent stderr 噪声/截断）必须容忍。

## D1：方向判别白名单

```
CLIENT_METHODS = ['initialize','session/new','session/prompt','session/load',
  'session/list','session/set_mode','session/cancel','_session/steering']
逐行：
  '^#'（行首字符，不 trim）→ 跳过（注释头；合法 JSON 行以 { 开头永不误杀——N2）
  method+id ∈ 白名单 → skipped_client += 1
  method 无 id      → Dispatch(msg)      （agent 通知：session/update 等）
  id+result|error   → Dispatch(msg)      （agent 响应）
  method+id 且 method == 'session/request_permission' → Dispatch(msg)（服务端请求）
  其他（解析失败/怪形状）→ bad += 1
```

白名单硬编码在 replay.vim 顶部（协议演进时同步——与 mock 夹具同维护节奏）。未知 method+id **不计入白名单也不回放**，归 bad 计数并在统计行提示（防未来协议面扩大时静默漏放）。

## D2：喂入缝隙

`session.Dispatch` 当前 script-local。**改为 export**（一行），回放器 import 后逐条调用。风险：export 即对外承诺——在函数头注释声明"回放/测试专用入口，正常流程经 protocol 回调"。Dispatch 内部分派逻辑零改动。

Dispatch 前置条件检查：session 未启动时 Dispatch 也能安全跑（HandleResponse 里对 session_id 的写入只是状态覆盖，render.Log 写 buffer——bufadd 的 chat buffer 无窗口也安全，M1 已验）。**但** HandlePermission 会写 perm 状态——回放含权限请求的流量会挂起权限等待，属预期（锚点断言可覆盖"权限行渲染"），不做特殊处理。

## D3：回放器结构（replay.vim）

```vim
vim9script
import autoload './session.vim'

const CLIENT_METHODS = [...]

export def Run(file: string): dict<any>   # 返回 {replayed, skipped_client, bad}
export def RunAndReport(file: string)     # Run + render.Log 统计行（:AgentReplay 用）
```

- readfile → 逐行 json_decode + Dispatch **整体 try/catch**（W2：decode 或分发任一异常计 bad，不中断）
- **B2 id 重映射**：回放的响应行 `id += 1000`（高段隔离）——HandleResponse 的语义 id（id_initialize/id_session_new/id_list/id_load/id_steer/id_set_mode）在组I 时刻早已漂移到远大于样本 id（1/2/3），但为消除对测试进程 id 历史的依赖（撞 id_load/id_steer 即假行为），重映射后必然落入形状判别段：new 响应（sessionId 形状）→ Register + ParseModes；prompt 响应（stopReason）→ BusyClear（queue 空安全）。**副作用约束**：Register 会把 claude/pi sessionId 以 current_preset 名义写入测试登记表——组I 断言「回放前后 Registry() 条目数不变」防污染扩散（登记表本身是 /tmp 测试路径，进程退出即弃）
- 无 timer/无 sleep：同步逐条喂（真实流量的顺序即因果序）
- steer_mode 污染说明：initialize 响应重映射后不走 id_initialize 分支 → 不会设 steer_mode='native'（该副作用仅在手动 :AgentReplay 干净进程出现，无害）
- **N-2 完整副作用清单**：session_id/cur_mode/session_title 被样本值覆盖（组I 后无消费者）；usage 由 new 边界清零后由样本 usage_update 重推（顺序：new 响应在 prompt 之前——正确）；perm 无样本则无挂起；busy 由 stopReason 收口。组I 后 AgentStop 兜底

## D4：样本入库

`t/replay/claude-full.jsonl`：2026-11-21 **重录**完整轮次样本（/tmp/replay_claude_full.jsonl，17 行——旧 /tmp/smoke_debug.jsonl 为 magpie 502 期的半链路残片，弃用）。文件头注释：
```
# source: claude-agent-acp (real), recorded 2026-11-20, scenario: full-chain smoke
# sanitized: no credentials present (manual session, wire contains cwd/path only)
```
`t/replay/pi-queued.jsonl`：从 research/steering-probe/steer_pi.jsonl（162 行）摘排队流核心段。**W3 摘录标准（复评修③：非连续挑选、保持因果序）**：样本几何为 Queued 在 L6、首个 stopReason 在 L136——连续段需 131 行超标；改为**按因果序挑选**：Queued chunk（L6 附近）→ 若干 agent_message_chunk → Starting queued message → stopReason 响应，共约 20 行；**不含 initialize/new 响应**（避免 Register/ParseModes 握手副作用）。头部标注"excerpt, non-contiguous, causal order preserved"。

`t/replay/README.md`：录制指南（设 g:agent_shell_debug → 跑场景 → grep 检查无 token/key 字样 → 头注释 → 入库）。

**入库检查单**（本 change 实施）：① 脱敏 `grep -iE 'sk-|api[_-]?key|authorization|bearer'`（字段名 totalTokens/模型描述文本不算——逐条人工确认）命中即中止；② 不含 `startedNewTurn` steering 响应（W5：会置 busy=true 无收口）；③ 回放 dry-run 一遍 stats 无 unknown_mid。

## D5：断言接入（t/ 主测试 + run.sh）

主测试新组（组I）：**插入点写死——组H H4 之后、chat dump 之前**（W4：现文件尾部是 dump → AgentStop → send_after_stop 断言，组I 必须在 dump 前；回放残留的 busy/perm 由其后既有 AgentStop 收口）。

**B3 锚点两件套（防历史行假匹配——M5-a 教训）**：
- 每条断言前记行数锚 `let s:anchor = len(getbufline(b,1,'$'))`，断言只匹配 `getbufline(b, s:anchor+1, '$')` 新增区
- 跨区断言用全 buffer 唯一特征串：claude sid 前缀（d06bf67b）、`pong`（mock 从不回）、统计行 `replayed=`

断言清单：
- `replay_claude_full`：Run('t/replay/claude-full.jsonl') → replayed==14 && skipped_client==3 && bad==0；新增区含 stopReason=end_turn、[AI] 行含 pong、`replayed=14` 统计行（RunAndReport 路径）
- `replay_usage_standard`：回放后调 agent_shell#session#ShowUsage() → 新增区含 `累计 total=` **总量口径**行（B-1 复评修正：样本 usage_update 仅 used 字段；inputTokens/outputTokens 拆分在 stopReason 响应 result.usage 中、HandleResponse 不消费——解析层改动超本 change 范围，待录场景记录）
- `replay_pi_queued`：Run('t/replay/pi-queued.jsonl') → replayed>0；新增区含 Queued message 回显
- `replay_registry_clean`（W-2 断言结构写死）：**独立二次回放** claude-full——首次回放（断言①）已把 claude-sid Register 进表；断言④回放前记 len(Registry())、再 Run 一次、回放后 len 相等（LRU 按 sessionId 去重：二次回放只前插更新同一条目，不新增）
- `replay_missing_file`：RunAndReport 不存在路径 → **新增区**含"文件不存在"（历史已有该串——行数锚隔离）
- `replay_bad_lines`：临时文件 2 行坏 JSON + 1 行合法通知 → bad==2 && replayed==1（回放不中断）

## D6：不做的事

- 不做双工仿真（client 请求的响应构造）
- 不按时间戳重放节奏
- 不改 DebugDump 格式（加方向标记会破坏与既有 dump 的兼容；shape 判别已够）
