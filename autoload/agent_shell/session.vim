vim9script
# session.vim — ACP 会话状态机：握手序列、轮次、权限挂起、会话生命周期（M3）
#
# 分发权归属：protocol 的行回调转发到这里；本模块解析后调 render 呈现。
# wire format（对拍真实适配器实证，勿改）：
#   - session/update 判别字段：params.update.sessionUpdate
#   - session/new|load params 必带 mcpServers: []（zod 校验，缺失即 -32602）
# M3 id 分派（add-session-management design D7，评审 B1 纠正）：
#   先比语义 id（id_session_new/id_list/id_load）→ 形状判别（result.sessionId
#   vs result.stopReason）→ stopReason 兜底。废除"id > ID_SESSION_NEW 一刀切"。

import autoload './protocol.vim'
import autoload './render.vim'
import autoload './presets.vim'
import autoload './diff.vim'
import autoload './sessions.vim'

var session_id = ''
var perm_id_pending = 0        # 挂起的权限请求 id（0 = 无）
var busy = false               # 轮次进行中
const ID_INITIALIZE = 1        # 握手 id 固定分段（历史兼容，分派已改语义 id）
const ID_SESSION_NEW = 2
var id_initialize = 0
var id_session_new = 0
var id_list = 0                # M3：最近一次 session/list 请求 id
var id_load = 0                # M3：最近一次 session/load 请求 id
var list_cursor = ''           # M3：翻页游标（同一请求链）
var list_page_count = 0        # 翻页防御（上限 5）
var collected_sessions: list<dict<any>> = []  # 翻页累积
var current_preset = ''        # M3：当前 preset 名（登记与 Current 用）
var session_title = ''         # M3：session_info_update 推送的 title
var pending_load: dict<any> = {}  # M3：自动启动链挂起的 load 目标（仅 Start 阶段持有）
var loading_entry: dict<any> = {} # M3：当前 load 的目标条目（LoadEntry 设置，响应清除——verify C-1）
var load_from_registry = false   # 当前 load 是否来自登记表路径（含自动启动链）

# M4：补全数据源（available_commands_update 缓存）
var avail_cmds: list<dict<any>> = []
# M4：usage 累计（B2 统一：标准字段分别累计；used 走总量降级口径）
var usage_in = 0
var usage_out = 0
var usage_total = 0
var last_usage: dict<any> = {}
# M4：prompt 队列（B1/W2：元素=完整 blocks 快照 + sid 快照）
var queue: list<dict<any>> = []
var dequeue_timer = 0
# M4：图片附件槽
var pending_image: dict<any> = {}  # {path, b64, mime}
# M4：模式与配置（握手 new 与 load 双处解析——2026-11-20 实测 load 也返回 modes）
var modes_list: list<dict<any>> = []
var cur_mode = ''
var config_opts: list<dict<any>> = []
var id_set_mode = 0
var last_set_mode = ''
# M5 steering（add-steering design D1：四态；进程级缓存——load/new 不重置，Stop 重置）
var steer_mode = 'unknown'   # unknown | native | queued | none
var id_steer = 0
var steer_probe_fails = 0

export def Running(): bool
  return protocol.Running()
enddef

export def SessionId(): string
  return session_id
enddef

export def IsBusy(): bool
  return busy
enddef

export def Title(): string
  return session_title
enddef

export def CurrentPreset(): string
  return current_preset
enddef

# M4 查询面
export def AvailableCommands(): list<dict<any>>
  return copy(avail_cmds)
enddef

export def UsageBrief(): string
  if usage_in > 0 || usage_out > 0
    return $' ⇅{usage_in}/{usage_out}'
  elseif usage_total > 0
    return $' Σ{usage_total}'
  endif
  return ''
enddef

export def QueueDepth(): number
  return len(queue)
enddef

export def PendingImage(): dict<any>
  return copy(pending_image)
enddef

# ---------- 启动 / 停止 ----------

export def Start(preset_name: string)
  current_preset = preset_name ==# '' ? 'mock' : preset_name
  if protocol.Running()
    render.Log('ACP', '已在运行')
    return
  endif
  var preset = presets.Resolve(preset_name)
  if empty(preset)
    # spec：agent-presets「未知名称」——报错并列出全部可用名，不 spawn
    render.Log('ERR', $'未知 agent preset：{preset_name}。可用：' .. presets.Names()->join(' '))
    return
  endif
  # steering preset 声明（add-steering design D4）
  if preset->has_key('steering')
    steer_mode = preset['steering']
  else
    steer_mode = 'unknown'
  endif
  render.Log('UI', $'--- agent-shell：启动 {preset_name}（{preset->get("desc", preset["cmd"][0])}）---')
  # vim9script funcref 类型规则（diag14 实证）：lambda 只转发 script-local def
  protocol.SetCallbacks(
    (line: string): void => OnLineCb(line),
    (line: string): void => OnStderrCb(line))
  var ok = protocol.Start(preset['cmd'])
  if !ok
    render.Log('ERR', $'agent 启动失败：{preset["cmd"][0]}（检查 PATH 与安装）')
    return
  endif
  Handshake()
enddef

# M3：无参 load 的自动启动入口（登记条目挂起，握手成功后自动 load）
export def StartWithPendingLoad(entry: dict<any>)
  pending_load = copy(entry)
  load_from_registry = true
  var preset_name = entry->get('preset', '')
  var preset = presets.Resolve(preset_name)
  if empty(preset)
    render.Log('ERR', $'登记的 preset「{preset_name}」已不存在。可用：' .. presets.Names()->join(' ') .. '（可 :AgentSessionList 重建）')
    pending_load = {}
    load_from_registry = false
    return
  endif
  Start(preset_name)
enddef

# protocol 行回调
def OnLineCb(line: string)
  OnLine(line)
enddef

def OnStderrCb(line: string)
  render.Log('ERR', line)
enddef

export def Stop()
  protocol.Stop()
  steer_mode = 'unknown'  # 进程级重置（add-steering design D1）
  steer_probe_fails = 0
  session_id = ''
  perm_id_pending = 0
  pending_load = {}
  loading_entry = {}
  ResetSessionState()
  # M3（W5）：清列表数据，防 A 家 sessionId 塞给 B 家
  sessions.ClearListEntries()
  if busy
    busy = false
    render.NotifyBusyChanged()
  endif
  render.Log('ACP', '已停止')
enddef

# ---------- 握手（spec：acp-session「ACP 握手序列」） ----------

def Handshake()
  id_initialize = protocol.NextId()
  SendRaw({
    jsonrpc: '2.0', id: id_initialize, method: 'initialize',
    params: {
      protocolVersion: 1,
      clientCapabilities: {
        fs: {read_text_file: false, write_text_file: false},
        terminal: false,
      },
    },
  })
  id_session_new = protocol.NextId()
  SendRaw({
    jsonrpc: '2.0', id: id_session_new, method: 'session/new',
    # mcpServers 必带空数组：真实适配器 zod 校验（缺失 -32602）
    params: {
      cwd: getcwd(),
      mcpServers: [],
    },
  })
enddef

# ---------- prompt 与权限（spec：acp-session） ----------

export def SendPromptText(text: string)
  if !EnsureReady()
    return
  endif
  # M4 组包：text?（空文本且有图→仅 image block）+ 挂起图片
  var blocks: list<dict<any>> = []
  if text !=# ''
    add(blocks, {type: 'text', text: text})
  endif
  if !empty(pending_image)
    add(blocks, {type: 'image', data: pending_image['b64'], mimeType: pending_image['mime']})
    var img = pending_image
    pending_image = {}
    render.Log('IMG', $'附件已发送：{img["path"]}（{len(img["b64"])} chars）')
  endif
  if empty(blocks)
    return
  endif
  if busy
    Enqueue(blocks)
    return
  endif
  FirePrompt(blocks)
enddef

def FirePrompt(blocks: list<dict<any>>)
  busy = true
  render.NotifyBusyChanged()
  SendRaw({
    jsonrpc: '2.0', id: protocol.NextId(), method: 'session/prompt',
    params: {sessionId: session_id, prompt: blocks},
  })
enddef

# M4 队列（design D2：B1/W2/W7）
def Enqueue(blocks: list<dict<any>>)
  var max = exists('g:agent_shell_queue_max') ? g:agent_shell_queue_max : 5
  if len(queue) >= max
    render.Log('QUEUE', $'队列已满（上限 {max}），本条被拒——请先 :AgentQueueClear')
    return
  endif
  add(queue, {blocks: copy(blocks), sid: session_id})
  render.Log('QUEUE', $'排队中（待发 {len(queue)} 条）——轮次结束自动发送')
enddef

export def QueueClear()
  var n = len(queue)
  if dequeue_timer != 0
    timer_stop(dequeue_timer)
    dequeue_timer = 0
  endif
  queue = []
  render.Log('QUEUE', $'已清空队列（{n} 条）')
enddef

# BusyClear 收口：出队（单例 timer 150ms）
def ScheduleDequeue()
  if !empty(queue) && dequeue_timer == 0
    dequeue_timer = timer_start(150, (t: number) => DequeueFire(t))
  endif
enddef

def DequeueFire(_: number)
  dequeue_timer = 0
  # 三重守卫（B1）：Running + 非 busy + 队首 sid == 当前会话
  if !protocol.Running() || busy || empty(queue)
    queue = []
    render.Log('QUEUE', '会话已变化，队列已清空')
    return
  endif
  if queue[0]['sid'] !=# session_id
    queue = []
    render.Log('QUEUE', '会话已切换，队列已清空（不串发到新会话）')
    return
  endif
  var item = remove(queue, 0)
  render.Log('QUEUE', $'出队发送（剩余 {len(queue)}）')
  FirePrompt(item['blocks'])
enddef

export def PermAnswer(optionId: string)
  if perm_id_pending == 0
    # spec：「无挂起请求时误触」——提示且不发消息
    render.Log('UI', '当前没有挂起的权限请求')
    return
  endif
  SendRaw({
    jsonrpc: '2.0',
    id: perm_id_pending,
    result: {outcome: {outcome: 'selected', optionId: optionId}},
  })
  render.Log('PERM', $'已答复：{optionId}')
  perm_id_pending = 0
enddef

# ---------- M3：list / load / new（sessions.vim 高层操作转发） ----------

export def RequestList()
  collected_sessions = []
  list_page_count = 0
  RequestListPage('')
enddef

def RequestListPage(cursor: string)
  var params: dict<any> = {}
  if cursor !=# ''
    params['cursor'] = cursor
  endif
  id_list = protocol.NextId()
  SendRaw({jsonrpc: '2.0', id: id_list, method: 'session/list', params: params})
enddef

export def LoadEntry(entry: dict<any>, from_registry: bool)
  load_from_registry = from_registry
  var sid = entry->get('sessionId', '')
  if sid ==# ''
    render.Log('SESS', '条目缺少 sessionId')
    return
  endif
  loading_entry = copy(entry)  # verify C-1：load 目标跟踪（响应时取 title/cwd/RemoveEntry）
  var cwd = entry->get('cwd', '') !=# '' ? entry['cwd'] : getcwd()
  id_load = protocol.NextId()
  SendRaw({
    jsonrpc: '2.0', id: id_load, method: 'session/load',
    params: {sessionId: sid, cwd: cwd, mcpServers: []},
  })
enddef

export def RequestNew()
  # 主动 new：走自增段 id，与首握手（id_session_new）可区分（design D7）
  var new_id = protocol.NextId()
  SendRaw({
    jsonrpc: '2.0', id: new_id, method: 'session/new',
    params: {cwd: getcwd(), mcpServers: []},
  })
enddef

# ---------- OnLine 分发（spec: acp-transport「请求 id 关联」） ----------

def OnLine(line: string)
  # 噪音行容错：非 JSON 行/解析失败一律忽略不中断
  var ok = true
  try
    var parsed = json_decode(line)
    if type(parsed) == v:t_dict
      Dispatch(parsed)
    endif
  catch
    ok = false
  endtry
enddef

# 回放/测试专用入口（add-traffic-replay D2）：正常流程经 protocol 回调；
# export 后 autoload 自动注册 agent_shell#session#Dispatch 全局名
export def Dispatch(msg: dict<any>)
  if msg->has_key('method')
    if msg['method'] ==# 'session/update'
      HandleUpdate(msg['params'])
    elseif msg['method'] ==# 'session/request_permission'
      HandlePermission(msg)
    endif
    # 其他通知：静默跳过，前向兼容
  elseif msg->has_key('id')
    HandleResponse(msg)
  endif
enddef

# update 分发：render 先渲染、diff 后入队打标
def HandleUpdate(params: any)
  var upd = params->get('update', {})
  var st = upd->get('sessionUpdate', '')
  render.Update(upd)
  if st ==# 'tool_call' || st ==# 'tool_call_update'
    diff.OnToolEvent(upd)
  elseif st ==# 'session_info_update'
    # M3（design D7）：桥推 title（M2 抓包实证此 update 存在）
    var t = upd->get('title', '')
    if t !=# ''
      session_title = t
    endif
  elseif st ==# 'available_commands_update'
    # M4：命令表缓存（补全数据源）
    avail_cmds = upd->get('availableCommands', [])
  elseif st ==# 'usage_update'
    AccumulateUsage(upd)
  endif
enddef

# M4 usage 累计（B2 统一：标准字段优先分别累计；used 走总量口径）
def AccumulateUsage(upd: dict<any>)
  last_usage = copy(upd)
  var it = upd->get('inputTokens', -1)
  var ot = upd->get('outputTokens', -1)
  if it >= 0 && ot >= 0
    usage_in += it
    usage_out += ot
  else
    var used = upd->get('used', -1)
    if used >= 0
      usage_total += used
    endif
  endif
enddef

export def ShowUsage()
  if usage_in > 0 || usage_out > 0
    render.Log('USE', $'累计 in={usage_in} out={usage_out}')
  elseif usage_total > 0
    render.Log('USE', $'累计 total={usage_total}（总量口径——agent 未提供输入/输出拆分）')
  else
    render.Log('USE', '尚无用量数据')
  endif
  if !empty(last_usage)
    var it = last_usage->get('inputTokens', -1)
    var ot = last_usage->get('outputTokens', -1)
    if it >= 0 && ot >= 0
      render.Log('USE', $'最近一轮 in={it} out={ot}')
    else
      render.Log('USE', $'最近一轮 used={last_usage->get("used", "?")}')
    endif
  endif
enddef

def HandleResponse(msg: dict<any>)
  var id = msg['id']
  if msg->has_key('error')
    var err = msg['error']
    if id == id_list
      render.Log('ERR', $'session/list 失败：{err->get("message", "")}')
    elseif id == id_load
      render.Log('ERR', $'session/load 失败（{err->get("code", "?")}）：{err->get("message", "")}')
      # verify C-1 修正：原 `!empty(pending_load) == false` 为反转条件（偶然正确）——
      # 登记表路径失败 → 清除条目（spec：失效条目降级）
      if load_from_registry && !empty(loading_entry)
        sessions.RemoveEntry(loading_entry->get('sessionId', ''))
        render.Log('SESS', '登记条目已失效并清除（可 :AgentSessionList 重建）')
      endif
      loading_entry = {}
      load_from_registry = false
    elseif id == id_session_new
      # spec：「session/new 被拒绝」——错误呈现，不进入可用会话
      render.Log('ERR', $'session/new 被拒绝（{err->get("code", "?")}）：{err->get("message", "")}')
    elseif id == id_steer
      HandleSteerError(err)
      return  # C-3：steer 错误不走末尾 BusyClear（挂起轮不受影响——spec R3-3）
    elseif id == id_set_mode
      render.Log('MODE', $'模式切换被拒（{err->get("code", "?")}）：{err->get("message", "")}')
    elseif id == id_initialize
      render.Log('ERR', $'initialize 失败：{err->get("message", "")}')
    else
      render.Log('ERR', $'请求失败（id={id}）：{err->get("message", "")}')
      # W6：queued steering 假阳性——专门提示
      if steer_mode ==# 'queued' && steer_queued_ctx
        render.Log('STEER', '该 agent 可能不支持排队（steering 降级后 prompt 被拒）——建议检查 preset steering 声明')
        steer_queued_ctx = false
      endif
    endif
    BusyClear()
    return
  endif
  var result = msg->get('result', {})

  # ---- M3 分派顺序（design D7）：语义 id 优先 ----
  if id == id_list
    HandleListResult(result)
    return
  endif
  if id == id_load
    HandleLoadResult(result)
    return
  endif
  if id == id_set_mode
    cur_mode = last_set_mode  # 成功后当前模式刷新
    render.Log('MODE', $'模式已切换：{cur_mode}')
    return
  endif
  if id == id_steer
    HandleSteerResult(result)
    return
  endif
  if id == id_session_new && type(result) == v:t_dict && result->has_key('sessionId')
    session_id = result['sessionId']
    render.Log('ACP', $'session 建立成功：{session_id}')
    ParseModes(result)
    ResetSessionState()  # M4：新会话边界（W1：usage 重置；空队列清理无害）
    sessions.Register(current_preset, session_id, session_title, getcwd())
    # 自动启动链：握手完成 → 触发挂起的 load（design D4 三段链第三段）
    if !empty(pending_load)
      var entry = pending_load
      pending_load = {}
      render.Log('SESS', $'握手完成，加载登记会话「{entry->get("title", "")}」…')
      LoadEntry(entry, true)
    endif
    return
  endif
  if id == id_initialize
    render.Log('ACP', '握手完成')
    # steering 能力声明（add-steering W4：claude 实测 _meta.steering.supported）
    var meta = type(result) == v:t_dict ? result->get('_meta', {}) : {}
    if type(meta) == v:t_dict
      var st = meta->get('steering', {})
      if type(st) == v:t_dict && st->get('supported', false) == true
        steer_mode = 'native'
      endif
    endif
    return
  endif

  # ---- 形状判别（自增段：主动 new / 轮次结束） ----
  if type(result) == v:t_dict && result->has_key('sessionId') && id != id_load
    # 主动 :AgentSessionNew 的响应
    session_id = result['sessionId']
    session_title = ''
    ParseModes(result)
    ResetSessionState()
    render.Log('SESS', $'── 新会话 ── {session_id}')
    sessions.Register(current_preset, session_id, session_title, getcwd())
    return
  endif
  if type(result) == v:t_dict && result->has_key('stopReason')
    var stop = result['stopReason']
    render.Log('ACP', $'轮次结束 stopReason={stop}')
    perm_id_pending = 0  # W-5：挂起轮结束（含 steer 注入）关权限残留窗口
    steer_queued_ctx = false  # 轮次完成清 steer 语境
    BusyClear()
    return
  endif
  # 未知形状：静默（前向兼容）
enddef

def HandleListResult(result: any)
  var r = type(result) == v:t_dict ? result : {}
  var page = r->get('sessions', [])
  if type(page) == v:t_list
    collected_sessions += page
  endif
  var cursor = r->get('nextCursor', '')
  if cursor !=# '' && type(cursor) == v:t_string && list_page_count < 5
    list_page_count += 1
    RequestListPage(cursor)  # 同一请求链：每页更新 id_list
    return
  endif
  sessions.RenderList(collected_sessions)
enddef

def HandleLoadResult(result: any)
  var r = type(result) == v:t_dict ? result : {}
  var new_sid = r->get('sessionId', '')
  if new_sid ==# ''
    # 降级（design Risks）：pi 桥响应形状未实证——警告但上下文已恢复
    render.Log('SESS', '警告：load 响应缺 sessionId（会话上下文已恢复，id 显示沿用旧值）')
    return
  endif
  session_id = new_sid
  ParseModes(r)  # M4：2026-11-20 实测 load 也返回 modes
  ResetSessionState()
  # verify C-1：title/cwd 从 loading_entry 取（原 pending_load 响应时恒空 → title 丢失）
  var title = loading_entry->get('title', '')
  var shown = title ==# '' ? strpart(new_sid, 0, 8) .. '…' : title
  render.Log('SESS', $'已恢复会话：{shown}（{strpart(new_sid, 0, 8)}…）')
  sessions.Register(current_preset, new_sid, title, loading_entry->get('cwd', getcwd()))
  loading_entry = {}
  pending_load = {}
  load_from_registry = false
enddef

def BusyClear()
  if busy
    busy = false
    render.NotifyBusyChanged()
  endif
  render.EndStream()  # 轮次结束收尾流式块（防跨轮次悬挂拼接）
  ScheduleDequeue()  # M4：轮次结束→队列依序接力
enddef

# M4 会话边界统一清理（design B1①/W1）：队列/附件/usage
def ResetSessionState()
  render.EndStream()  # 会话切换收尾流式块（防跨会话悬挂拼接）
  if dequeue_timer != 0
    timer_stop(dequeue_timer)
    dequeue_timer = 0
  endif
  if !empty(queue)
    render.Log('QUEUE', $'会话已结束，队列清空（{len(queue)} 条）')
    queue = []
  endif
  if !empty(pending_image)
    render.Log('IMG', '会话已结束，挂起附件清除')
    pending_image = {}
  endif
  usage_in = 0
  usage_out = 0
  usage_total = 0
enddef

# ---------- 权限 ----------

def HandlePermission(msg: dict<any>)
  perm_id_pending = msg['id']
  var opts = msg['params']->get('options', [])
  var names = opts->mapnew((_: number, o: any) => o->get('text', o->get('optionId', '?')))
  render.Log('PERM', 'Agent 请求权限 → y 允许 / n 拒绝  [' .. names->join(' | ') .. ']')
enddef

# ---------- 内部 ----------

def EnsureReady(): bool
  if !protocol.Running()
    render.Log('ERR', 'agent 未启动，先 :AgentStart [preset]')
    return false
  endif
  if session_id == ''
    render.Log('ERR', '会话尚未建立（握手未完成）')
    return false
  endif
  return true
enddef

# ---------- M5 steering（add-steering design D1/D2） ----------

# 入口：组包+清槽一次完成（W-4）；分派按 steer_mode×busy 矩阵
export def SteerText(text: string)
  if !EnsureReady()
    return
  endif
  var blocks: list<dict<any>> = []
  if text !=# ''
    add(blocks, {type: 'text', text: text})
  endif
  if !empty(pending_image)
    add(blocks, {type: 'image', data: pending_image['b64'], mimeType: pending_image['mime']})
    pending_image = {}
  endif
  if empty(blocks)
    render.Log('STEER', '输入区为空')
    return
  endif
  # preset 显式声明优先（Start 时已写入 steer_mode）
  if steer_mode ==# 'none'
    render.Log('STEER', '该 agent 不支持转向（preset 声明 none）——用普通 <CR> 发送')
    return
  endif
  if steer_mode ==# 'native'
    FireSteer(blocks)
    return
  endif
  if steer_mode ==# 'queued'
    SteerQueued(blocks)
    return
  endif
  # unknown：首探（idle 也探——B1' 裁决）——回显延迟到结果确认（防降级双显：native 才回显）
  steer_last_blocks = copy(blocks)
  id_steer = protocol.NextId()
  SendRaw({
    jsonrpc: '2.0', id: id_steer, method: '_session/steering',
    params: {sessionId: session_id, prompt: blocks},
  })
enddef

def EchoSteerText(blocks: list<dict<any>>)
  var t = ''
  for b in blocks
    if b->get('type', '') ==# 'text'
      t = b['text']
      break
    endif
  endfor
  if t !=# ''
    render.Log('你·STEER', t)
  endif
enddef

var steer_last_blocks: list<dict<any>> = []  # 首探降级重发用

def FireSteer(blocks: list<dict<any>>)
  id_steer = protocol.NextId()
  SendRaw({
    jsonrpc: '2.0', id: id_steer, method: '_session/steering',
    params: {sessionId: session_id, prompt: blocks},
  })
  # B2：本地回显仅 native（W-1：queued 由 agent 回推防双显）
  EchoSteerText(blocks)
enddef

var steer_queued_ctx = false  # W6：当前 prompt 错误是否源于 steer 降级

def SteerQueued(blocks: list<dict<any>>)
  steer_queued_ctx = true
  # W-2：客户端队列非空时交错警告
  if busy && !empty(queue)
    render.Log('STEER', $'注意：客户端队列 {len(queue)} 条将与桥端排队交错发送')
  endif
  if busy
    render.Log('STEER', '排队语义：已交由 agent 服务端排队')
    FirePrompt(blocks)
  else
    render.Log('STEER', '排队语义：空闲态按普通消息发送')
    FirePrompt(blocks)
  endif
enddef

def HandleSteerResult(result: any)
  var r = type(result) == v:t_dict ? result : {}
  var outcome = r->get('outcome', '')
  var was_probe = steer_mode ==# 'unknown'
  steer_mode = 'native'
  steer_probe_fails = 0
  if was_probe && !empty(steer_last_blocks)
    # 首探成功：此刻才回显（native 确认）
    EchoSteerText(steer_last_blocks)
  endif
  steer_last_blocks = []
  if outcome ==# 'injected'
    render.Log('STEER', '↪ 已注入当前轮次')
  elseif outcome ==# 'startedNewTurn'
    render.Log('STEER', '↪ 已开启新轮次')
    busy = true  # 桥自起轮——客户端 busy 对齐
    render.NotifyBusyChanged()
  else
    render.Log('STEER', $'↪ 未知响应：{json_encode(r)}')
  endif
enddef

def HandleSteerError(err: dict<any>)
  if err->get('code', 0) == -32601
    # 方法不存在 → 降级 queued + 重发本次内容
    steer_mode = 'queued'
    steer_probe_fails = 0
    render.Log('STEER', 'agent 不支持 steering 方法——降级为服务端排队语义')
    if !empty(steer_last_blocks)
      var blocks = steer_last_blocks
      steer_last_blocks = []
      SteerQueued(blocks)
    endif
    return
  endif
  # 其他错误：计数收敛（W3：连续 3 次 → none）
  steer_probe_fails += 1
  render.Log('ERR', $'steering 失败（{err->get("code", "?")}）：{err->get("message", "")}')
  if steer_probe_fails >= 3
    steer_mode = 'none'
    render.Log('STEER', '连续探测失败——标记为不支持（可用 preset steering 声明覆盖）')
  endif
enddef

# queued 假阳性：session/prompt 报错时的专门提示挂在 FirePrompt 的失败呈现外——
# 由 HandleResponse 既有 error 分支呈现；此处只拦 steer 语境
# （实现从简：queued 模式下 prompt 错误统一呈现 + W6 提示行）

# M4：modes/configOptions 解析（握手 new 与 load 双处——D4 + 2026-11-20 实测）
def ParseModes(result: dict<any>)
  var m = result->get('modes', {})
  if type(m) == v:t_dict
    var cur = m->get('currentModeId', '')
    var avail = m->get('availableModes', [])
    if type(avail) == v:t_list && !empty(avail)
      modes_list = avail
      cur_mode = cur
    endif
  endif
  var co = result->get('configOptions', [])
  if type(co) == v:t_list && !empty(co)
    config_opts = co
  endif
enddef

export def ShowModes()
  if empty(modes_list)
    render.Log('MODE', '当前 agent 未提供模式列表')
    return
  endif
  for m in modes_list
    var mark = m->get('id', '') ==# cur_mode ? ' *' : ''
    render.Log('MODE', $'{m->get("id", "?")}{mark} — {m->get("name", "")}：{m->get("description", "")}')
  endfor
enddef

export def SetMode(mode_id: string)
  if empty(modes_list)
    render.Log('MODE', '当前 agent 未提供模式列表')
    return
  endif
  var valid = false
  for m in modes_list
    if m->get('id', '') ==# mode_id
      valid = true
      break
    endif
  endfor
  if !valid
    var names = modes_list->mapnew((_: number, m: dict<any>) => m->get('id', '?'))
    render.Log('MODE', $'无效模式：{mode_id}。可选：' .. names->join(' | '))
    return
  endif
  id_set_mode = protocol.NextId()
  last_set_mode = mode_id
  SendRaw({
    jsonrpc: '2.0', id: id_set_mode, method: 'session/set_mode',
    params: {sessionId: session_id, modeId: mode_id},
  })
enddef

export def ShowConfig()
  if empty(config_opts)
    render.Log('CFG', '当前 agent 未提供配置项')
    return
  endif
  for co in config_opts
    var vals = co->get('options', [])->mapnew((_: number, o: dict<any>) => o->get('value', o->get('name', '?')))
    var ro = co->get('id', '') ==# 'model' ? '（仅展示——无标准切换 RPC）' : ''
    render.Log('CFG', $'{co->get("name", co->get("id", "?"))}: {co->get("currentValue", "?")} {ro}  可选: ' .. vals->join(' | '))
  endfor
enddef

# M4：图片挂载（W4：getfsize<0 显式拒；shellescape；2MB 上限）
export def AttachImage(path: string)
  var full = expand(path)
  if !filereadable(full)
    render.Log('IMG', $'文件不存在：{full}')
    return
  endif
  var size = getfsize(full)
  if size < 0
    render.Log('IMG', $'无法读取文件大小：{full}')
    return
  endif
  if size > 2 * 1024 * 1024
    render.Log('IMG', $'图片超过 2MB 上限（{size} bytes）')
    return
  endif
  var ext = tolower(fnamemodify(full, ':e'))
  var mime = ''
  if ext ==# 'png'
    mime = 'image/png'
  elseif ext ==# 'jpg' || ext ==# 'jpeg'
    mime = 'image/jpeg'
  elseif ext ==# 'webp'
    mime = 'image/webp'
  else
    render.Log('IMG', $'不支持的格式 .{ext}（支持 png/jpg/jpeg/webp）')
    return
  endif
  var b64 = ''
  try
    b64 = substitute(system('base64 < ' .. shellescape(full)), '[\n\r]', '', 'g')
  catch
    render.Log('IMG', 'base64 编码失败（需要 unix base64 命令）')
    return
  endtry
  if v:shell_error != 0 || b64 ==# ''
    render.Log('IMG', 'base64 编码失败')
    return
  endif
  pending_image = {path: full, b64: b64, mime: mime}
  render.Log('IMG', $'附件已挂载：{full}（{size} bytes → {len(b64)} chars）——下次发送携带')
enddef

def SendRaw(msg: dict<any>)
  protocol.DumpOutgoing(json_encode(msg))
  if !protocol.Send(msg)
    render.Log('ERR', '发送失败：agent 未运行')
    BusyClear()
  endif
enddef
