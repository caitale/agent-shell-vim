vim9script
# session.vim — ACP 会话状态机：握手序列、轮次、权限挂起、OnLine 分发
#
# 分发权归属（design D2）：protocol 的行回调转发到这里；本模块解析后调
# render 呈现。单向依赖 session -> {protocol, render}，render 为纯被动方。
#
# wire format（对拍真实适配器实证，勿改）：
#   - session/update 判别字段：params.update.sessionUpdate
#   - session/new params 必带 mcpServers: []（zod 校验，缺失即 -32602）

import autoload './protocol.vim'
import autoload './render.vim'
import autoload './presets.vim'

var session_id = ''
var perm_id_pending = 0        # 挂起的权限请求 id（0 = 无）
const ID_INITIALIZE = 1        # 握手 id 固定分段（由本模块向 protocol 取号后记录）
const ID_SESSION_NEW = 2
var id_initialize = 0
var id_session_new = 0

export def Running(): bool
  return protocol.Running()
enddef

export def SessionId(): string
  return session_id
enddef

# ---------- 启动 / 停止 ----------

export def Start(preset_name: string)
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
  # vim9script funcref 类型规则（diag14 实证）：
  # lambda 体内直接调用 import 的函数（render.Log 等）时，返回类型被推断为
  # any，精确 func(string):void 形参即报 E1013。解法：lambda 只转发
  # script-local def（编译期类型已知），不直接调 import 符号。
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

# ---------- OnLine 分发（spec：acp-transport「请求 id 关联」） ----------

def OnLine(line: string)
  # 噪音行容错（spec: acp-transport）：非 JSON 行/解析失败一律忽略不中断。
  # 注意 mock 夹具启动即输出噪音行，真实适配器也可能有非消息输出。
  var ok = true
  try
    var parsed = json_decode(line)
    if type(parsed) == v:t_dict
      Dispatch(parsed)
    endif
  catch
    ok = false  # 非 JSON 行：忽略
  endtry
enddef

def Dispatch(msg: dict<any>)
  if msg->has_key('method')
    if msg['method'] ==# 'session/update'
      HandleUpdate(msg['params'])
    elseif msg['method'] ==# 'session/request_permission'
      HandlePermission(msg)
    endif
    # 其他通知（_auth/status_update 等）：静默跳过，前向兼容
  elseif msg->has_key('id')
    HandleResponse(msg)
  endif
enddef

def HandleResponse(msg: dict<any>)
  var id = msg['id']
  if msg->has_key('error')
    var err = msg['error']
    if id == id_session_new
      # spec：「session/new 被拒绝」——错误呈现，不进入可用会话
      render.Log('ERR', $'session/new 被拒绝（{err->get("code", "?")}）：{err->get("message", "")}')
    elseif id == id_initialize
      render.Log('ERR', $'initialize 失败：{err->get("message", "")}')
    else
      render.Log('ERR', $'请求失败（id={id}）：{err->get("message", "")}')
    endif
    return
  endif
  var result = msg->get('result', {})
  if id == id_session_new && type(result) == v:t_dict && result->has_key('sessionId')
    session_id = result['sessionId']
    render.Log('ACP', $'session 建立成功：{session_id}')
  elseif id == id_initialize
    # 握手响应仅确认协议版本接受（transport 级完成）
    render.Log('ACP', '握手完成')
  elseif id > ID_SESSION_NEW
    var stop = type(result) == v:t_dict ? result->get('stopReason', '?') : '?'
    render.Log('ACP', $'轮次结束 stopReason={stop}')
  endif
enddef

# ---------- update 处理（spec：acp-session「wire format 判别」） ----------

def HandleUpdate(params: any)
  # 实证 wire format：params.update.sessionUpdate 为判别字段
  var upd = params->get('update', {})
  render.Update(upd)
enddef

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
  endif
enddef
