vim9script
# acp.vim — Vim9 最小 ACP 客户端（spike 验证版 v3）
# 架构：Vim --(job/stdio, JSON-RPC 按行)--> ACP agent（mock 或真实）
#
# 用法：
#   :AcpStart                启动 agent 并握手
#   :AcpOpen                 打开聊天 buffer（交互模式）
#     在 acp-chat buffer 写一行消息按 <CR> 发送
#     权限请求到达后按 y（允许）/ n（拒绝）
#   :AcpSend <text>          直接发送（headless/脚本友好）
#   :AcpPermAllow / AcpPermReject   答复权限
#   :AcpStop                 停止
#
# Agent 选择（启动前设置全局变量，启动后修改无效）：
#   g:acp_agent_cmd  完整命令行 list。默认 mock：
#     ['python3', '<script_dir>/mock_agent.py']
#   真实 Claude（需 npm i -g @agentclientprotocol/claude-agent-acp）：
#     let g:acp_agent_cmd = ['claude-agent-acp']
#   注意：真实 agent 首个响应可能稍慢（node 启动），握手超时给足。
#
# 设计要点：buffer 用 bufadd() 创建（无窗口依赖），headless (-es) 与
# 交互模式行为一致；窗口仅在 :AcpOpen 时打开。

const SCRIPT_DIR = expand('<sfile>:h')
const BUFNAME = 'acp-chat'

var job: job = null_job
var session_id = ''
var next_id = 10          # 1=initialize, 2=session/new 预留
var perm_id_pending = 0   # 挂起的权限请求 id（0 = 无）

# ---------- 聊天 buffer（无窗口依赖） ----------
def ChatBuf(): number
  if !bufexists(BUFNAME)
    var b = bufadd(BUFNAME)
    bufload(b)
    setbufvar(b, '&buftype', 'nofile')
    setbufvar(b, '&bufhidden', 'hide')
    setbufvar(b, '&swapfile', 0)
  endif
  return bufnr(BUFNAME)
enddef

def Log(kind: string, text: string)
  appendbufline(ChatBuf(), '$', $'[{kind}] {text}')
enddef

def OpenChat()
  var b = ChatBuf()
  if bufwinnr(b) == -1
    exe $'sbuffer {b}'
  endif
  # buffer-local 映射（仅在窗口中可见时生效）
  nnoremap <buffer> <CR> <ScriptCmd>SendCurrentLine()<CR>
  nnoremap <buffer> y <ScriptCmd>PermAnswer('allow_once')<CR>
  nnoremap <buffer> n <ScriptCmd>PermAnswer('reject_once')<CR>
  normal! G
enddef

def SendToAgent(msg: dict<any>)
  if job == null_job
    Log('ERR', 'agent 未启动，先 :AcpStart')
    return
  endif
  ch_sendraw(job, json_encode(msg) .. "\n")
enddef

# ---------- job 回调：agent 的每行输出 ----------
def OnJobOut(_: channel, line: string)
  if line =~ '^\s*$'
    return
  endif
  # 原始消息落盘（诊断用）：g:acp_debug 设为日志路径即启用
  if exists('g:acp_debug') && g:acp_debug != ''
    writefile([line], g:acp_debug, 'a')
  endif
  var msg = json_decode(line)
  if type(msg) != v:t_dict
    return
  endif
  if msg->has_key('method')
    if msg['method'] == 'session/update'
      HandleUpdate(msg['params'])
    elseif msg['method'] == 'session/request_permission'
      HandlePermission(msg)
    endif
  elseif msg->has_key('id')
    var id = msg['id']
    var result = msg->get('result', {})
    if id == 2 && type(result) == v:t_dict && result->has_key('sessionId')
      session_id = result['sessionId']
      Log('ACP', $'session 建立成功：{session_id}')
    elseif id >= 10
      var stop = type(result) == v:t_dict ? result->get('stopReason', '?') : '?'
      Log('ACP', $'轮次结束 stopReason={stop}')
    endif
  endif
enddef

def HandleUpdate(params: any)
  # 真实 ACP wire format：params.update.sessionUpdate 为判别字段（实测
  # claude-agent-acp）。mock 旧格式（params.sessionUpdate.sessionUpdateType）
  # 已废弃，mock_agent.py 已同步对齐。
  var upd = params->get('update', {})
  var st = upd->get('sessionUpdate', '')
  if st == 'user_message_chunk'
    Log('你', upd->get('content', {})->get('text', ''))
  elseif st == 'agent_message_chunk'
    Log('AI', upd->get('content', {})->get('text', ''))
  elseif st == 'plan'
    var first = upd->get('entries', [])->get(0, {})
    Log('PLAN', $'{first->get("content", "")} ({first->get("status", "")})')
  elseif st == 'tool_call'
    Log('TOOL', $'{upd->get("title", "")}: {upd->get("status", "")}')
  elseif st == 'available_commands_update'
    var cmds = upd->get('availableCommands', [])
    Log('CMD', $'可用斜杠命令 {len(cmds)} 个：' .. cmds->mapnew((_, c) => c->get('name', '?'))->join(' '))
  endif
enddef

def HandlePermission(msg: dict<any>)
  perm_id_pending = msg['id']
  var opts = msg['params']->get('options', [])
  var names = opts->mapnew((_, o) => o->get('text', o->get('optionId', '?')))
  Log('PERM', 'Agent 请求权限 → y 允许 / n 拒绝  [' .. names->join(' | ') .. ']')
enddef

def PermAnswer(optionId: string)
  if perm_id_pending == 0
    Log('UI', '当前没有挂起的权限请求')
    return
  endif
  SendToAgent({
    jsonrpc: '2.0',
    id: perm_id_pending,
    result: {outcome: {outcome: 'selected', optionId: optionId}},
  })
  Log('PERM', $'已答复：{optionId}')
  perm_id_pending = 0
enddef

def OnJobErr(_: channel, line: string)
  # 适配器（claude-agent-acp）把诊断日志写 stderr（[session/create] 等），
  # 默认静默降噪；设 g:acp_verbose = 1 可查看全部 stderr。
  if exists('g:acp_verbose') && g:acp_verbose && line !~ '^\s*$'
    Log('ERR', line)
  endif
enddef

# ---------- 发送 ----------
def SendPromptText(text: string)
  SendToAgent({
    jsonrpc: '2.0',
    id: next_id,
    method: 'session/prompt',
    params: {
      sessionId: session_id,
      prompt: [{type: 'text', text: text}],
    },
  })
  next_id += 1
enddef

def SendCurrentLine()
  var line = getline('.')
  if line =~ '^\s*$' || line =~ '^\['
    echom '请写一行不以 [ 开头的普通文本再按 <CR>'
    return
  endif
  SendPromptText(line)
enddef

# ---------- 生命周期 ----------
def AgentCmd(): list<string>
  if exists('g:acp_agent_cmd') && type(g:acp_agent_cmd) == v:t_list
    return g:acp_agent_cmd
  endif
  return ['python3', SCRIPT_DIR .. '/mock_agent.py']
enddef

def StartAgent()
  if job != null_job
    Log('ACP', '已在运行')
    return
  endif
  var cmd = AgentCmd()
  Log('UI', $'--- acp.vim spike：启动 {cmd[0]} ---')
  job = job_start(cmd, {
    out_mode: 'nl',
    err_mode: 'nl',
    out_cb: (ch, msg) => OnJobOut(ch, msg),
    err_cb: (ch, msg) => OnJobErr(ch, msg),
  })
  SendToAgent({
    jsonrpc: '2.0', id: 1, method: 'initialize',
    params: {
      protocolVersion: 1,
      clientCapabilities: {
        fs: {read_text_file: false, write_text_file: false},
        terminal: false,
      },
    },
  })
  SendToAgent({
    jsonrpc: '2.0', id: 2, method: 'session/new',
    # 真实 agent（claude-agent-acp）zod 校验要求 mcpServers 必须为数组；
    # mock agent 忽略此字段。clientCapabilities 同步声明无 fs/terminal。
    params: {
      cwd: getcwd(),
      mcpServers: [],
    },
  })
enddef

def StopAgent()
  if job != null_job
    job_stop(job)
    job = null_job
    Log('ACP', '已停止')
  endif
enddef

command! AcpStart call StartAgent()
command! AcpStop call StopAgent()
command! AcpOpen call OpenChat()
command! -nargs=1 AcpSend call SendPromptText(<q-args>)
command! AcpPermAllow call PermAnswer('allow_once')
command! AcpPermReject call PermAnswer('reject_once')
