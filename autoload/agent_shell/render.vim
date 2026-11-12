vim9script
# render.vim — 聊天 buffer 渲染与窗口呈现（纯被动方：不依赖任何模块）
#
# 设计（design D1/D2）：buffer 用 bufadd/bufload 创建，无窗口依赖，
# headless (-es) 与交互模式行为一致（spike 实证 headless 下 :new 静默失败）。
# 本模块不 import 其他模块——被 session 调用，单向依赖。

const BUFNAME = 'agent-shell-chat'

# 聊天 buffer（懒创建，headless 安全）
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

# 通用日志行（spec：各场景的"呈现"通道）
export def Log(kind: string, text: string)
  appendbufline(ChatBuf(), '$', $'[{kind}] {text}')
enddef

# session/update 渲染入口（spec：acp-session「wire format 判别」已知类型 + tasks 4.2 逐类型行为）
# upd 结构：{sessionUpdate: '<type>', ...payload}
export def Update(upd: any)
  var st = upd->get('sessionUpdate', '')
  if st ==# 'user_message_chunk'
    Log('你', upd->get('content', {})->get('text', ''))
  elseif st ==# 'agent_message_chunk'
    Log('AI', upd->get('content', {})->get('text', ''))
  elseif st ==# 'plan'
    var first = upd->get('entries', [])->get(0, {})
    Log('PLAN', $'{first->get("content", "")} ({first->get("status", "")})')
  elseif st ==# 'tool_call'
    Log('TOOL', $'{upd->get("title", "")}: {upd->get("status", "")}')
  elseif st ==# 'available_commands_update'
    var cmds = upd->get('availableCommands', [])
    Log('CMD', $'可用斜杠命令 {len(cmds)} 个：' .. cmds->mapnew((_: number, c: any) => c->get('name', '?'))->join(' '))
  elseif st ==# 'agent_thought_chunk'
    # 提示级渲染（tasks 4.2）：思考流不逐 chunk 呈现，仅在首个 chunk 标记一次
    if !did_mark_thought
      Log('AI', '…（思考中）')
      did_mark_thought = true
    endif
  elseif st ==# 'usage_update'
    # 提示级渲染（tasks 4.2）：单行摘要
    Log('USE', CompactUsage(upd))
  else
    # 未知类型：静默跳过，前向兼容（spec「未知类型容错」）
  endif
enddef

var did_mark_thought = false

def CompactUsage(upd: dict<any>): string
  var u = upd->get('usage', upd)
  var parts: list<string> = []
  for [label, key] in [['in', 'inputTokens'], ['out', 'outputTokens'], ['ctx', 'contextWindow']]
    if u->has_key(key)
      add(parts, $'{label}={u[key]}')
    endif
  endfor
  return empty(parts) ? '(usage)' : parts->join(' ')
enddef

# 每个用户轮次开始时由 session 侧调用重置思考标记（当前由 Update 的
# user_message_chunk 隐式触发即可；M1 输入区落地时改为显式调用）
export def ResetTurn()
  did_mark_thought = false
enddef

# ---------- 窗口呈现（spec：spike OpenChat 等价迁移） ----------

export def Open()
  var b = ChatBuf()
  if bufwinnr(b) == -1
    execute $'sbuffer {b}'
  endif
  # buffer-local 按键（仅在窗口可见时生效）
  nnoremap <buffer> <CR> <ScriptCmd>SendCurrentLine()<CR>
  nnoremap <buffer> y <ScriptCmd>AnswerPerm('allow_once')<CR>
  nnoremap <buffer> n <ScriptCmd>AnswerPerm('reject_once')<CR>
  normal! G
enddef

def SendCurrentLine()
  # 延迟 import 避免循环依赖（session 已 import 本模块）
  import autoload './session.vim'
  var line = getline('.')
  if line =~ '^\s*$' || line =~ '^\['
    echom '请写一行不以 [ 开头的普通文本再按 <CR>'
    return
  endif
  ResetTurn()
  session.SendPromptText(line)
enddef

def AnswerPerm(optionId: string)
  import autoload './session.vim'
  session.PermAnswer(optionId)
enddef

# ---------- M1 挂载点（design D6：预留不实现） ----------
# 输入区：M1 将在聊天 buffer 尾部建立常驻可编辑输入区，
# 届时 SendCurrentLine 由输入区 <CR> 取代。此函数为占位。
export def OnInputArea()
  # M1: 实现输入区渲染与键绑定
enddef
