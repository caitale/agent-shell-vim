# Design: add-production-features

## Context

M0–M3 六模块骨架稳定（49 断言）。M4 是五件高频摩擦的消除：补全/队列/成本/模式/图片。契约已抓包（2026-11-20，magpie 502 不影响握手类探测）。

## wire 契约（claude 桥实测，/tmp/m4_probe*.jsonl）

```
session/new result:
  modes: {currentModeId: 'auto', availableModes: [{id,name,description}]}
  configOptions: [{id:'mode',type:'select',currentValue,options:[{value,name}]},
                  {id:'model',...options:[default/opus/fable/sonnet/haiku/codex…/zcode…]}]
session/set_mode {sessionId, modeId} → result:{}（实测 'plan' 成功）
session/set_model → -32601 Method not found（模型切换无标准 RPC——仅展示）
prompt image block: {type:'image', data:<base64-no-prefix>, mimeType:'image/png'|'image/jpeg'|'image/webp'}（ACP 标准）
available_commands_update: {availableCommands:[{name,description}]}（M0 起已渲染）
usage_update: {used, size} 或字段变体——M1 的 CompactUsage 已兼容 inputTokens/outputTokens；M4 累计取 used（claude 变体）优先、无则 inputTokens/outputTokens
```

## Goals / Non-Goals

**Goals**：五能力全 headless 可测（补全测数据源非菜单）；队列状态机与 busy 生命周期咬合；契约兼容（used/变体字段、无 modes 的桥降级）。

**Non-Goals**：补全菜单的视觉交互（headless 不可测，归手动清单）；模型切换 RPC（不存在）；多图批量（一次一张，够用）；图片粘贴（剪贴板 API 平台差异大——`:AgentImage <path>` 显式路径起步）；登记表损坏重置断言以外的 M3 遗留。

## Decisions

### D1：complete.vim——补全数据源与触发

- `FilesFor(prefix)`：`globpath(cwd, prefix.'**', 0, 1)` 截断至 50 项 + 相对化；`@` 后无前缀给顶层目录概览；N2：node_modules 级仓库全量 glob 后截断会卡顿——**前缀驱动**（无前缀只给一层目录列表，有前缀才递归 glob）
- `CommandsFor(prefix)`：缓存自 session.vim 的 `available_commands_update` 解析（session 新增模块态 `avail_cmds` + export `AvailableCommands()`）
- 触发：输入区 insert 映射。`@`/行首 `/` 的字符触发用 `inoremap <buffer> @ <Plug>…` 不可靠（vim9 + headless 未验）——**用 `<C-X><C-U>` 语义**：`inoremap <buffer> <expr> <CR> SendInput()` 之外，注册 `completefunc`（输入区 buffer-local `setlocal completefunc=agent_shell#complete#Input`）+ 用户按 `<C-X><C-U>` 呼出；**默认再给一键映射 `<Tab>`**（输入区 buffer-local inoremap，经光标行判定：行内有 `@` 尾随词 → 文件补全；行首 `/` → 命令；否则默认 Tab 行为不动）。菜单交互归手动清单，断言只测 `FilesFor/CommandsFor` 返回列表。
- **Tab 冲突声明（W5）**：buffer-local inoremap 覆盖用户缩进插件的 Tab——README 声明 + `g:agent_shell_no_tab_map=1` 逃生口（不注册 Tab 映射，completefunc 仍可用）
- N4：M2 遗留死挂载点 render.OnInputArea() 本 change 删除
- completefunc 为 buffer-local（历史区 insert 触发无害——勿"修复"）

### D2：队列——session 状态机内嵌（评审 B1/W1/W2/W7 重写）

```
var queue: list<dict<any>>     # FIFO；元素 = {blocks: [...], sid: 入队时 session_id 快照}
var dequeue_timer = 0          # 单例 timer 句柄（0=无）
SendPromptText 组包后：busy → enqueue（容量检查 g:agent_shell_queue_max 默认 5；
  入队元素快照完整 block 列表（含 image）+ 当前 session_id——W2：冻结时刻内容防中途换图错配）
BusyClear(): 队列非空且 dequeue_timer==0 → 单例 timer_start(150ms)
DequeueFire():（timer 回调，script-local def）
  三重守卫：protocol.Running() && !busy && 队首元素 sid == 当前 session_id
  守卫不过（会话已换/已停）→ 清队列+提示（B1 串话防线），不发送
  通过 → 出队一条 SendRaw 直发；发送失败 → 清队列+提示（W7 自旋防线）
会话边界统一清理（B1①）：Stop() / HandleLoadResult 成功 / 主动 new 响应
  → timer_stop(dequeue_timer) + queue=[] + pending_image={} + usage 清零（W1）
  （注：Stop 的 busy 复位维持现状内联，不入 BusyClear——避免反启 timer）
:AgentQueueClear 命令（含 timer_stop）+ [QUEUE] 提示行
```
- 150ms 延迟：busy statusline 刷新与发送解耦；**150ms 窗口内换会话**由 sid 快照守卫兜底（双保险：边界清理+回调守卫）

### D3：usage 累计——update 解析处顺收

- session 模块态：`usage_in/usage_out/usage_total/last_usage`；HandleUpdate 的 usage_update 分支（评审 B2 统一）：**inputTokens+outputTokens 存在→分别累计；否则 used→计入 usage_total（总量口径）**；`last_usage` 存最近原始 dict；:AgentUsage 呈现时标准口径缺失则展示总量并标注
- 换会话重置：HandleLoadResult 成功分支 + RequestNew 响应分支清零
- `:AgentUsage`：`[USE] 累计 in=Na out=Nb ｜ 最近一轮 in=Ma out=Mb`
- statusline 简报（render.StatusLine 内 query session.UsageBrief()）：busy 段尾附 `⇅in/out`——headless 不影响（M1 同款）

### D4：模式/配置——握手数据缓存 + set_mode

- 握手 new 响应分支解析 `modes`/`configOptions` 存模块态（`modes_list/cur_mode/config_opts`）
- `:AgentMode`：无参列出（`*` 标当前）；带参校验在列表内 → set_mode RPC（id 语义登记 `id_set_mode`，响应对话式呈现确认/错误）；无效 → 提示列表
- `:AgentConfig`：遍历 configOptions 呈现 `name: currentValue（可选: a|b|c）`
- 无 modes 数据的桥（降级）：提示"当前 agent 未提供模式列表"

### D5：图片附件——待发附件槽 + 组包

```
var pending_image: dict<any>   # {path, b64, mime}
:AgentImage <path>: 校验（扩展名→mime 映射 png/jpg/jpeg/webp；**getfsize < 0 显式拒**（W4：-1 会误判通过）；size ≤ 2*1024*1024）
  → system('base64 < ' .. shellescape(path))（W4：路径必须 shellescape——空格/;注入面）strip 换行
  （unix 通用，CI ubuntu 有；Windows 声明不支持——本插件本就 unix 优先）
  agent 未启动时允许挂载（发送时 EnsureReady 兜底校验）
SendPromptText: pending_image 非空 → prompt=[text?, image]（无文本时仅 image block）
发送后清 pending_image；聊天提示 [IMG] 附件已发送（path 大小）
```

### D6：mock 夹具扩展

- usage_update：每轮 completed 后推 `{used: <轮次递增>, size: 272000, inputTokens: 100, outputTokens: 50}`（双字段都给——测试累计与变体兼容）
- available_commands：握手后推两条固定命令
- set_mode：`modeId == 'plan'` → `{}`；其他 → -32602（测校验路径在客户端，mock 只需成功路径+一个失败）
- prompt 含 image block：回显 `[image: <mimeType> <len(b64)> chars]`（不解析内容）

## Risks / Trade-offs

- [completefunc/Tab 映射 headless 不可测菜单] → 断言只测数据源函数；映射注册归手动清单
- [base64 依赖外部命令] → system('base64') 失败 catch 提示；Windows 不在支持矩阵（README 声明）
- [队列 150ms 延迟的时序测试] → 断言等 stopReason 后 sleep 400ms 再查
- [usage 字段变体（used=快照非增量？）] → claude 实测 used 随轮增长——按增量处理有风险：**累计取 inputTokens/outputTokens 优先（标准字段），used 仅展示**；mock 双给字段
- [大 image 的 json_encode 体积] → 2MB 上限即 ~2.7MB base64，单行发送 job 缓冲可承受

## Migration Plan

纯增量。49 断言预期零改动回归。回滚 revert。

## Open Questions

无（模型切换不存在已实证、粘贴留后续、多图不做均已声明）。
