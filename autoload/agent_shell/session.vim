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
  session_id = ''
  perm_id_pending = 0
  pending_load = {}
  loading_entry = {}
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
  busy = true
  render.NotifyBusyChanged()
  SendRaw({
    jsonrpc: '2.0', id: protocol.NextId(), method: 'session/prompt',
    params: {
      sessionId: session_id,
      prompt: [{type: 'text', text: text}],
    },
  })
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

def Dispatch(msg: dict<any>)
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
    elseif id == id_initialize
      render.Log('ERR', $'initialize 失败：{err->get("message", "")}')
    else
      render.Log('ERR', $'请求失败（id={id}）：{err->get("message", "")}')
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
  if id == id_session_new && type(result) == v:t_dict && result->has_key('sessionId')
    session_id = result['sessionId']
    render.Log('ACP', $'session 建立成功：{session_id}')
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
    return
  endif

  # ---- 形状判别（自增段：主动 new / 轮次结束） ----
  if type(result) == v:t_dict && result->has_key('sessionId')
    # 主动 :AgentSessionNew 的响应
    session_id = result['sessionId']
    session_title = ''
    render.Log('SESS', $'── 新会话 ── {session_id}')
    sessions.Register(current_preset, session_id, session_title, getcwd())
    return
  endif
  if type(result) == v:t_dict && result->has_key('stopReason')
    var stop = result['stopReason']
    render.Log('ACP', $'轮次结束 stopReason={stop}')
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

def SendRaw(msg: dict<any>)
  protocol.DumpOutgoing(json_encode(msg))
  if !protocol.Send(msg)
    render.Log('ERR', '发送失败：agent 未运行')
    BusyClear()
  endif
enddef
