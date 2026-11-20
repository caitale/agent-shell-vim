# Design: add-session-management

## Context

M0–M2 单会话架构：session.vim 模块级单份状态（sessionId/busy/perm），M0 风险表已预案"M3 改为字典按会话键控"。本设计在此基础上加会话生命周期，不动单进程单活跃会话模型。

## wire 契约（两桥实测 2026-11-20，probe 存档 /tmp/sess_list*.jsonl）

```
session/list  → result: {sessions: [{sessionId, cwd, title, updatedAt}], nextCursor?: string|null}
                （claude 按 updatedAt 倒序；pi 空表 + nextCursor:null + _meta）
session/load  params: {sessionId, cwd, mcpServers: []}
                （claude 桥内部走 claude -p --resume <uuid|title>，非法 ID 报 -32603）
session/new   既有（M0 起在用）；load/new 的 id 关联走 transport 既有分帧
```

## Goals / Non-Goals

**Goals**：列表/恢复/新建/登记四能力闭环；登记表跨 Vim 重启存活；两桥契约兼容（nextCursor/空表/UUID 校验错误路径）。

**Non-Goals**：**多进程并行会话**（一个 agent 进程同一时刻一个活跃会话——多会话并行需 M0 风险表预案的"字典化重构 + 多 job"，收益/复杂度比留 M5 评估）；编辑器↔终端互通（需终端侧会话发现协议，单独立项）；load 后历史消息回放（桥不提供 transcript，聊天 buffer 只标记恢复来源）。

## Decisions

### D1：新模块 sessions.vim——登记表与列表状态的家

```
autoload/agent_shell/sessions.vim
  var registry: list<dict>          # {preset, sessionId, title, lastUsed}，cap 20 条 LRU
  var list_entries: list<dict>       # 最近一次 session/list 结果（带 source 序号）
  Register(preset, sessionId, title) / Registry() / RemoveEntry(sessionId)
  SaveRegistry() / LoadRegistry()    # ~/.cache/agent-shell-vim/sessions.json
```

依赖：sessions → session（发送 RPC）+ render（渲染）；session 成功握手/load 后**回调 sessions.Register**（session → sessions 单向边，render 不依赖 sessions）。环形依赖处理与 M1 同款：顶层 import，vim9 环内符号惰性解析已实证可行。

### D2：id 关联——语义 id 段扩展

session.vim 既有 `id_initialize=1 / id_session_new=2` 固定段 + `next_id` 自增。M3 增加语义 id 登记：`id_list` / `id_load` 记录最近一次 list/load 的请求 id（并发窗口内单飞——list 未回时不发新 list，load 同理；后发覆盖前发按"最近 id 优先匹配"处理，陈旧响应丢弃）。

### D3：列表渲染与序号行——聊天 buffer 内联，不开新窗

`:AgentSessionList` 渲染到聊天 buffer（`[SESS] ── 会话列表 ──` 头 + 每项一行）：

```
[SESS] 1. Ping pong test              (11-15 02:33, …/agent-shell-vim)
[SESS] 2. probe_target.txt edit       (11-14 02:47, /private/tmp)
```

- 序号行数据存 sessions.list_entries；`:AgentSessionLoad <n>` 按序号取条目
- **不开新窗口/tab**：与聊天流同 buffer 符合"会话即对话"心智；diff 审查开 tab 是"离开对话看文件"，列表是"对话内的选择"，交互语义不同
- headless 断言友好（getbufline 匹配 `[SESS]` 行）
- **防线复用（N2）**：`[SESS]` 行首 `[` 恰好落入 chat-ui「历史行 [ 开头受发送防线保护」语义——列表行天然不可被误发，未来改前缀须保持 `[` 开头

### D4：load 语义与失败保持

```
LoadEntry(entry):
  if busy → 拒绝提示（D7 守卫）
  if agent 未运行（三段异步链，W1 时序）：
    pending_load = entry                     # 挂起待发（握手 new 响应到达后自动触发）
    Start(entry.preset)                      # 启动+握手
    ├─ 握手失败/preset 不存在 → pending_load 清空 + 错误呈现（含"登记 preset 已失效"提示 RemoveEntry 选项）
    └─ 握手成功 → 发送 session/load {sessionId, cwd: entry.cwd, mcpServers: []}
  else 直接发送 load
  响应 result.sessionId → session_id 替换 + render「已恢复会话：<title>」+ Register 刷新
  响应 error → render 错误；来自自动启动路径 → RemoveEntry + 提示
```

- **cwd 用条目的原始 cwd**（agent 恢复需要原上下文；claude 桥实测会话带 cwd）
- 当前会话在 load 成功前完全不动（失败零影响）

### D5：登记表存储——~/.cache/agent-shell-vim/sessions.json

- `mkdir -p` + `writefile([json_encode()])`；读取 try/catch（文件损坏→重置为空表并警告一次）
- **不存对话内容**（隐私 + 桥已有 transcript），只存指针：preset/sessionId/title/lastUsed/cwd
- LRU cap 20：Register 时去重（同 sessionId 更新）+ 超长裁剪最旧
- headless 测试用 `g:agent_shell_registry_path` 覆盖路径（不污染真实登记表——测试隔离关键）

### D6：mock 夹具扩展（契约对齐）

- `session/list` → 固定两条（W4 区分设计）：`sess_mock_known`（可 load 成功）与 `sess_mock_expired`（load 报 -32602）+ `nextCursor: null`——`:AgentSessionLoad 2` 即驱动错误路径
- `session/load`：匹配 known → 成功响应 `{sessionId, modes:{}}` + **self.sid 同步替换**（N8 夹具 wire 保真）+ 推 `agent_message_chunk("已恢复 mock 会话")`；expired/其他 → error -32602
- 形态切换（W2）：环境变量 `MOCK_SESS_MODE=empty` → 空表（驱动"空列表"场景）；`=paged` → 两页（首页 1 条 + nextCursor，次页 1 条 + null，驱动"分页合并"）
- list 响应带 cwd（load 参数按条目 cwd 组装——契约对齐）

### D7：命令、id 分派与自动登记（评审 B1 纠正）

- 命令：`:AgentSessionList` / `:AgentSessionLoad [n?]` / `:AgentSessionNew` / `:AgentSessionCurrent`
- **id 可区分**（评审纠正：原"不可区分"论断错误——`id_session_new` 是变量，主动 new 走自增段，id 恒大于当前 `id_session_new`）：
  - `id == id_session_new` → 首握手 new（渲染"session 建立成功"）
  - `id == id_list / id_load` → list/load 响应（各自语义分支）
  - **形状判别兜底**：自增段响应 `result` 含 `sessionId` 且非 list/load 的 → 主动 new；`result` 含 `stopReason` → 轮次结束。修掉原 `elseif id > ID_SESSION_NEW` 一刀切误判（list/load/主动 new 都会被当轮次结束打 stopReason=?）
- 分派顺序（HandleResponse 自增段）：先比语义 id（new/list/load），再形状判别，最后才 stopReason 兜底
- 登记时机：首握手 new 成功 + 主动 new 成功 + load 成功，统一 sessions.Register
- title 来源：`session_info_update`（M2 实证桥会推 title）——session.vim 解析存模块状态（供登记与 Current 展示）
- **busy 守卫（W7）**：busy 期间拒绝 load/list/new（提示"轮次进行中"）——避免在途轮次与换会话互踩

## Risks / Trade-offs

- [pi 桥 load 响应形状未实测（list 已实证）] → 解析只取 result.sessionId（存在性校验，缺失则警告但会话上下文已恢复——降级不阻断）；**冒烟清单显式记档 load 成功的请求+响应形状（W8）**
- [登记表与真实会话漂移（外部 claude 清了历史）] → D4 失效条目自动清除 + 提示
- [id 并发竞态（list 未回又 load）] → D2 最近 id 优先 + 陈旧丢弃；翻页视为同一请求链（每页更新 id_list，页 N 响应后才发 N+1）
- [~/.cache 不可写（权限）] → try/catch 静默降级为内存登记（当次会话内可用）；路径经 expand()（N3）
- [**序号跨 agent 失效（W5）**：Stop 后换 preset，list_entries 残留] → Stop/Start 时清空 list_entries（A 家 sessionId 不塞给 B 家）
- [**两 Vim 实例并发写登记表（W6）**] → 接受 last-write-wins（并发窗口小、登记表可重建——list 随时可再拉）；保存时机=每次 Register 即写（变更即写，崩溃丢失窗口最小）
- [updatedAt ISO8601 → 显示格式（N4）] → 无内建解析：直接截断原串显示（`YYYY-MM-DDTHH:MM` 取局部），不做本地化转换
- [session/list params 形状] → 实测 `{}` 两桥皆过（JSON-RPC 允许省略），保持现状
- [M0 风险表"字典化"未做] → 接受：单活跃会话模型下无需求；M5 多会话并行时一并重构

## Migration Plan

纯增量（新模块 + session.vim 两处分支 + render 一处渲染 + 四命令）。既有 35 断言零改动预期回归绿。回滚 revert 即可。

## Open Questions

无（编辑器↔终端互通已在 Non-Goals 明确单独立项）。
