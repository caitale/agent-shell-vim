vim9script
# sessions.vim — 会话登记表（LRU 持久化）与列表状态
#
# 设计（add-session-management design D1/D3/D5）：
#   registry: {preset, sessionId, title, cwd, lastUsed}，cap 20 LRU
#   存储 ~/.cache/agent-shell-vim/sessions.json（g:agent_shell_registry_path 可覆盖）
#   list_entries: 最近一次 session/list 结果（序号选择的依据）
# 依赖：sessions → session（RPC）+ render（渲染）；session 握手/load 成功后回调
# Register（session → sessions 单向边；render 不依赖本模块）。

import autoload './session.vim'
import autoload './render.vim'

var registry: list<dict<any>> = []
var registry_loaded = false
var list_entries: list<dict<any>> = []
const REG_CAP = 20

# ---------- 登记表 ----------

def RegPath(): string
  if exists('g:agent_shell_registry_path') && type(g:agent_shell_registry_path) == v:t_string && g:agent_shell_registry_path !=# ''
    return expand(g:agent_shell_registry_path)
  endif
  return expand('~/.cache/agent-shell-vim/sessions.json')
enddef

def LoadRegistry()
  if registry_loaded
    return
  endif
  registry_loaded = true
  registry = []
  try
    var path = RegPath()
    if filereadable(path)
      var raw = readfile(path)->get(0, '')
      if raw !=# ''
        var parsed = json_decode(raw)
        if type(parsed) == v:t_list
          registry = parsed
        endif
      endif
    endif
  catch
    # 损坏 → 重置为空表（design：警告一次）
    registry = []
    render.Log('SESS', '登记表读取失败已重置：' .. v:exception)
  endtry
enddef

def SaveRegistry()
  try
    var path = RegPath()
    mkdir(fnamemodify(path, ':h'), 'p')
    writefile([json_encode(registry)], path)
  catch
    # 不可写 → 静默降级为内存登记（design Risks）
  endtry
enddef

export def Register(preset: string, sessionId: string, title: string, cwd: string = '')
  LoadRegistry()
  # 去重更新（同 sessionId 刷新）
  registry = filter(copy(registry), (i: number, e: dict<any>) => e['sessionId'] !=# sessionId)
  insert(registry, {
    preset: preset,
    sessionId: sessionId,
    title: title,
    cwd: cwd,
    lastUsed: strftime('%Y-%m-%dT%H:%M:%S'),
  }, 0)
  # LRU cap
  if len(registry) > REG_CAP
    registry = slice(registry, 0, REG_CAP)
  endif
  SaveRegistry()
enddef

# 测试隔离入口：重置内存登记表（生产代码勿用）
export def ResetForTest()
  registry = []
  registry_loaded = true
enddef

export def Registry(): list<dict<any>>
  LoadRegistry()
  return copy(registry)
enddef

export def RemoveEntry(sessionId: string)
  LoadRegistry()
  var before = len(registry)
  registry = filter(registry, (i: number, e: dict<any>) => e['sessionId'] !=# sessionId)
  if len(registry) < before
    SaveRegistry()
  endif
enddef

# 最近一条登记（无参 load 的目标）
export def Latest(): dict<any>
  LoadRegistry()
  return empty(registry) ? {} : copy(registry[0])
enddef

# ---------- 列表状态与渲染 ----------

export def ListEntries(): list<dict<any>>
  return copy(list_entries)
enddef

export def SetListEntries(entries: list<dict<any>>)
  list_entries = copy(entries)
enddef

export def ClearListEntries()
  list_entries = []
enddef

# 按序号取条目（1-based；无效返回空 dict）
export def EntryByNumber(n: number): dict<any>
  if n < 1 || n > len(list_entries)
    return {}
  endif
  return copy(list_entries[n - 1])
enddef

# 渲染到聊天 buffer（design D3：[SESS] 行首 [ 复用发送防线）
export def RenderList(entries: list<dict<any>>)
  SetListEntries(entries)
  if empty(entries)
    render.Log('SESS', '无历史会话（:AgentSessionList 刷新）')
    return
  endif
  render.Log('SESS', '── 会话列表（:AgentSessionLoad <序号> 恢复）──')
  var i = 1
  for e in entries
    var title = e->get('title', '') ==# '' ? '(未命名)' : e['title']
    var ts = e->get('updatedAt', '')
    if len(ts) >= 16
      ts = strpart(ts, 5, 11)  # MM-DDTHH:MM 截断显示（design N4）
    endif
    var cwd_tail = fnamemodify(e->get('cwd', ''), ':t')
    render.Log('SESS', $'{i}. {title}  ({ts}, {cwd_tail})')
    i += 1
  endfor
enddef

# ---------- 高层操作（命令入口调用） ----------

export def ListSessions()
  if !session.Running()
    render.Log('SESS', 'agent 未启动，先 :AgentStart [preset]')
    return
  endif
  if session.IsBusy()
    render.Log('SESS', '轮次进行中，稍后再试')
    return
  endif
  session.RequestList()
enddef

# 命令分发：:AgentSessionLoad 无参→登记表最近一条；带参→列表序号
export def LoadDispatch(arg: string)
  if arg ==# ''
    LoadLatest()
  else
    LoadByNumber(str2nr(arg))
  endif
enddef

export def LoadByNumber(n: number)
  # verify C-2：busy 守卫（spec：轮次中 load/list/new 任一拒绝）
  if session.IsBusy()
    render.Log('SESS', '轮次进行中，稍后再试')
    return
  endif
  # verify SUGGESTION ⑤：带参 load 的 agent 未启动提示（scenario 8 可达）
  if !session.Running()
    render.Log('SESS', 'agent 未启动：先 :AgentStart，或用无参 :AgentSessionLoad 自动恢复')
    return
  endif
  var entry = EntryByNumber(n)
  if empty(entry)
    render.Log('SESS', $'序号无效（1-{len(ListEntries())}），先 :AgentSessionList')
    return
  endif
  session.LoadEntry(entry, false)
enddef

# 无参 load：登记表最近一条；agent 未运行时自动启动（三段异步链入口）
export def LoadLatest()
  # busy 守卫优先（spec：轮次中拒绝切换，先于一切判断）
  if session.IsBusy()
    render.Log('SESS', '轮次进行中，稍后再试')
    return
  endif
  var entry = Latest()
  if empty(entry)
    render.Log('SESS', '登记表为空，无可恢复会话；用 :AgentSessionList 从 agent 历史选择')
    return
  endif
  if session.Running()
    session.LoadEntry(entry, true)
  else
    render.Log('SESS', $'agent 未运行，按登记 preset「{entry["preset"]}」自动启动…')
    session.StartWithPendingLoad(entry)
  endif
enddef

export def NewSession()
  if !session.Running()
    render.Log('SESS', 'agent 未启动，先 :AgentStart [preset]')
    return
  endif
  if session.IsBusy()
    render.Log('SESS', '轮次进行中，稍后再试')
    return
  endif
  session.RequestNew()
enddef

# :AgentSteer [text?]（无参=转发输入区提取；带参直发）
export def SteerDispatch(arg: string)
  if arg ==# ''
    # 经 render 提取（复用 SteerInput 全逻辑）
    call agent_shell#render#SteerInput()
  else
    session.SteerText(arg)
  endif
enddef

# :AgentMode [modeId?]（无参列表/带参切换）
export def ModeDispatch(arg: string)
  if arg ==# ''
    session.ShowModes()
  else
    session.SetMode(arg)
  endif
enddef

export def ShowCurrent()
  var sid = session.SessionId()
  var title = session.Title()
  var preset = session.CurrentPreset()
  if sid ==# ''
    render.Log('SESS', $'当前无活跃会话（preset: {preset}）')
  else
    render.Log('SESS', $'preset={preset}  session={sid}' .. (title !=# '' ? $'  title={title}' : ''))
  endif
enddef
