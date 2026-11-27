vim9script
# render.vim — 聊天 buffer 渲染、窗口布局、输入区、busy 指示、折叠与高亮
#
# 设计依据：openspec/changes/add-chat-ui-baseline/design.md（D1-D5）
#  - buffer 结构：[历史区][分隔线][输入区]，input_lnum 锚定分隔线行号
#  - 历史追加插到分隔线之前；输入区常驻尾部；undo 树切断防锚点漂移
#  - busy 画在窗口局部 statusline（零 buffer 残留），timer 仅窗口显示时启动
#  - tool_call 折叠块用自定义 marker «as»,«/as»（防误折叠 vim 内容）
#  - 依赖说明：M1 起 render 顶层 import session（IsBusy 轮询）。
#    session 也 import render —— 形成环，但 vim9script 的 import autoload
#    是符号级惰性加载，实测环内相互调用在 def 编译期可解析（本轮验证）；
#    若后续出问题，回退方案是 NotifyBusyChanged 由 session 直调本模块私有 API

import autoload './session.vim'

const BUFNAME = 'agent-shell-chat'
const SEPARATOR = '── input ──'
const FOLD_OPEN = '«as»'
const FOLD_CLOSE = '«/as»'

var input_lnum = 0          # 分隔线所在行（其下全部是输入区）
var busy_timer = 0          # 0 = 无 timer
var busy_frame_idx = 0
const BUSY_FRAMES = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']

# ---------- buffer 基础 ----------

def ChatBuf(): number
  if !bufexists(BUFNAME)
    var b = bufadd(BUFNAME)
    bufload(b)
    setbufvar(b, '&buftype', 'nofile')
    setbufvar(b, '&bufhidden', 'hide')
    setbufvar(b, '&swapfile', 0)
    # undo 树切断（design W3）：appendbufline 会进 undo 历史，
    # 用户一次 u 就能把分隔线/输入区卷掉导致锚点失步
    setbufvar(b, '&undolevels', -1)
    # 初始结构：空历史 + 分隔线 + 一行空输入
    appendbufline(b, '$', [SEPARATOR, ''])
    input_lnum = len(getbufline(b, 1, '$')) - 1
  endif
  Reanchor()
  return bufnr(BUFNAME)
enddef

# 按分隔线文本重锚（undo/手改的最后防线，每次 Log 入口调用）
def Reanchor()
  var b = bufnr(BUFNAME)
  if b == -1
    return
  endif
  var lines = getbufline(b, 1, '$')
  var found = 0
  for i in range(len(lines) - 1, 0, -1)  # 从尾找最近一条分隔线
    if lines[i] ==# SEPARATOR
      found = i + 1  # 行号从 1 计
      break
    endif
  endfor
  if found > 0
    input_lnum = found
  else
    EnsureInputArea()
  endif
enddef

# 兜底：分隔线/输入区被删光时重建（返回分隔线行号）
def EnsureInputArea(): number
  var b = bufnr(BUFNAME)
  if b == -1
    call ChatBuf()
    return input_lnum
  endif
  var lines = getbufline(b, 1, '$')
  var has_sep = index(lines, SEPARATOR) >= 0
  if !has_sep
    if len(lines) == 1 && lines[0] ==# ''
      deletebufline(b, 1)
    endif
    appendbufline(b, '$', [SEPARATOR, ''])
    input_lnum = len(getbufline(b, 1, '$')) - 1
  endif
  return input_lnum
enddef

# 历史追加：插到分隔线之前，锚点下移（输入区保持最尾）
def LogLines(rows: list<string>)
  var b = ChatBuf()
  appendbufline(b, input_lnum - 1, rows)
  input_lnum += len(rows)
enddef

export def Log(kind: string, text: string)
  LogLines([$'[{kind}] {text}'])
enddef

# ---------- update 渲染（逐类型行为，spec: acp-session + chat-ui） ----------

var did_mark_thought = false
# 流式行状态（2026-11-22 真实 pi 试用暴露：token 级 chunk 逐行渲染碎屏——
# ACP 语义 chunk 应拼接。stream_lnum=0 表示不在流式块中）
var stream_lnum = 0
# toolCallId → 折叠块摘要行号（diff 审查标记定位，design D5）
var tool_blocks: dict<number> = {}
# toolCallId → {title, status, mark}：摘要行结构化重建的真源（避免正则摘放）
var tool_meta: dict<dict<any>> = {}

export def Update(upd: any)
  var st = upd->get('sessionUpdate', '')
  if st ==# 'user_message_chunk'
    EndStream()
    did_mark_thought = false
    Log('你', upd->get('content', {})->get('text', ''))
  elseif st ==# 'agent_message_chunk'
    StreamChunk(upd->get('content', {})->get('text', ''))
  elseif st ==# 'plan'
    EndStream()
    var first = upd->get('entries', [])->get(0, {})
    Log('PLAN', $'{first->get("content", "")} ({first->get("status", "")})')
  elseif st ==# 'tool_call'
    EndStream()
    RenderToolCall(upd)
  elseif st ==# 'tool_call_update'
    RenderToolCallUpdate(upd)
  elseif st ==# 'available_commands_update'
    EndStream()
    var cmds = upd->get('availableCommands', [])
    Log('CMD', $'可用斜杠命令 {len(cmds)} 个：' .. cmds->mapnew((_: number, c: any) => c->get('name', '?'))->join(' '))
  elseif st ==# 'agent_thought_chunk'
    if !did_mark_thought
      Log('AI', '…（思考中）')
      did_mark_thought = true
    endif
  elseif st ==# 'usage_update'
    EndStream()
    Log('USE', CompactUsage(upd))
  else
    # 未知类型静默跳过（spec：前向兼容）
  endif
enddef

# 流式拼接渲染：首 chunk 开块，后续 chunk 拼接到流式行（遇 \n 起新行）
def StreamChunk(text: string)
  if text ==# ''
    return
  endif
  var b = ChatBuf()
  if stream_lnum == 0
    LogLines([$'[AI] '])
    stream_lnum = input_lnum - 1
  endif
  # 按 \n 分段：末段留在当前行，其余各成一行
  var segs = split(text, "\n", true)
  var cur = getbufline(b, stream_lnum, stream_lnum)[0]
  for i in range(len(segs))
    if i == 0
      setbufline(b, stream_lnum, cur .. segs[0])
    else
      appendbufline(b, stream_lnum + i - 1, segs[i])
      stream_lnum += 1
      input_lnum += 1
    endif
  endfor
enddef

# 流式块收尾（轮次结束/其他消息类型到达/会话切换时调用；幂等）
export def EndStream()
  stream_lnum = 0
enddef

# tool_call 折叠块（design D3）：
#   ▸ TOOL title: status «as»1
#     <content>
#   «/as»
def RenderToolCall(upd: dict<any>)
  var title = upd->get('title', '')
  var status = upd->get('status', '')
  var content = ''
  var c = upd->get('content', {})
  if type(c) == v:t_dict
    content = c->get('text', '')
  endif
  var rows: list<string> = [$'▸ TOOL {title}: {status} {FOLD_OPEN}1']
  if content !=# ''
    for line in split(content, "\n")
      add(rows, '  ' .. line)
    endfor
  endif
  add(rows, FOLD_CLOSE)
  LogLines(rows)
  # 记录摘要行锚（LogLines 后行号=插入区首行-1-其余行……直接取：插入后摘要行=input_lnum-len(rows)）
  var id = upd->get('toolCallId', '')
  if id !=# ''
    tool_blocks[id] = input_lnum - len(rows)
    tool_meta[id] = {title: title, status: status, mark: ''}
  endif
enddef

# tool_call_update 渲染（M1 遗留修正）：title 演进/状态更新；diff content 追加展示
def RenderToolCallUpdate(upd: dict<any>)
  var id = upd->get('toolCallId', '')
  var lnum = get(tool_blocks, id, 0)
  var meta = get(tool_meta, id, {})
  if lnum == 0 || empty(meta)
    return  # 对应块未渲染——静默
  endif
  # 合并演进字段（title/status 更新；mark 保留既有）
  var t = upd->get('title', '')
  if t !=# ''
    meta['title'] = t
  endif
  var st = upd->get('status', '')
  if st !=# ''
    meta['status'] = st
  endif
  tool_meta[id] = meta
  # 结构化重建摘要行（验证报告 W-1 连带修复：正则摘放标记的路径全部废除）
  var b = bufnr(BUFNAME)
  setbufline(b, lnum, $'▸ TOOL {meta["title"]}: {meta["status"]}{meta["mark"]} {FOLD_OPEN}1')
enddef

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

# M5 steering 输入区入口（<M-CR> 映射转发；提取逻辑与 SendInput 一致）
export def SteerInput()
  var b = ChatBuf()
  var lines = getbufline(b, input_lnum + 1, '$')
  var start = 0
  while start < len(lines) && lines[start] =~# '^\s*$'
    start += 1
  endwhile
  var last = len(lines) - 1
  while last >= start && lines[last] =~# '^\s*$'
    last -= 1
  endwhile
  if last < start
    # 空输入但可能有挂起图片——交给 SteerText 判定（组包含图）
    session.SteerText('')
    return
  endif
  var text = join(lines[start : last], "\n")
  if text =~# '^\['
    echom '输入以 [ 开头（历史区防线），整条拒绝'
    return
  endif
  session.SteerText(text)
  deletebufline(b, input_lnum + 1, '$')
  appendbufline(b, '$', '')
enddef

# diff 审查标记（design D5）：state ∈ reviewing|accepted|rejected|pending
export def MarkToolCall(id: string, state: string)
  var b = bufnr(BUFNAME)
  var lnum = get(tool_blocks, id, 0)
  var meta = get(tool_meta, id, {})
  if lnum == 0 || empty(meta)
    return
  endif
  var mark = state ==# 'accepted' ? ' ✓' : state ==# 'rejected' ? ' ✗' : state ==# 'reviewing' ? '（审查中）' : '（待审查）'
  meta['mark'] = mark
  tool_meta[id] = meta
  setbufline(b, lnum, $'▸ TOOL {meta["title"]}: {meta["status"]}{meta["mark"]} {FOLD_OPEN}1')
enddef

# ---------- 输入区发送（export：映射与测试共用入口，design W7） ----------

export def SendInput()
  var b = ChatBuf()
  var lines = getbufline(b, input_lnum + 1, '$')
  # 保序 join：仅去首尾空白行，中间空行保留（spec：粘贴多行不失真）
  var start = 0
  while start < len(lines) && lines[start] =~# '^\s*$'
    start += 1
  endwhile
  var last = len(lines) - 1
  while last >= start && lines[last] =~# '^\s*$'
    last -= 1
  endwhile
  if last < start
    # B4：空输入但有挂起图片 → 放行（仅 image block 由 session 组包）
    if empty(session.PendingImage())
      echom '输入区为空'
      return
    endif
    session.SendPromptText('')
    # 清空输入区（保持一行）
    deletebufline(b, input_lnum + 1, '$')
    appendbufline(b, '$', '')
    return
  endif
  var text = join(lines[start : last], "\n")
  if text =~# '^\['
    echom '输入以 [ 开头（历史区防线），整条拒绝'
    return
  endif
  did_mark_thought = false
  session.SendPromptText(text)
  # 清空输入区（保留一行空行）
  deletebufline(b, input_lnum + 1, '$')
  appendbufline(b, '$', '')
  var w = bufwinnr(b)
  if w != -1
    win_execute(w, $'normal! {input_lnum + 1}G')
  endif
enddef

# ---------- 窗口布局（design D5） ----------

def LayoutOf(arg: string): string
  if arg ==# 'right' || arg ==# 'bottom'
    return arg
  endif
  if exists('g:agent_shell_layout') && (g:agent_shell_layout ==# 'right' || g:agent_shell_layout ==# 'bottom')
    return g:agent_shell_layout
  endif
  return 'bottom'
enddef

export def Open(layout_arg: string = '')
  var layout = LayoutOf(layout_arg)
  var b = ChatBuf()
  var win = bufwinnr(b)
  if win == -1
    # headless（-es）下 split 静默失败：bufwinnr 仍 -1，窗口分支自然跳过
    if layout ==# 'right'
      var w = exists('g:agent_shell_right_width') ? g:agent_shell_right_width : 46
      # vim9 def 内 execute 'Nsplit' 的数字前缀会被当 range（E1050），
      # 必须先 split 再 resize 两步（实证）
      execute 'rightbelow vsplit'
      execute $'vertical resize {w}'
    else
      var h = exists('g:agent_shell_bottom_height') ? g:agent_shell_bottom_height : 12
      execute 'rightbelow split'
      execute $'resize {h}'
    endif
    execute $'buffer {b}'
    win = bufwinnr(b)
  endif
  if win != -1
    SetupWindow(win)
    win_execute(win, $'normal! {input_lnum + 1}G')
  endif
enddef

def SetupWindow(win: number)
  win_execute(win, 'setlocal foldmethod=marker')
  win_execute(win, $'setlocal foldmarker={FOLD_OPEN},{FOLD_CLOSE}')
  win_execute(win, 'setlocal foldlevel=1')
  win_execute(win, 'setlocal statusline=%{agent_shell#render#StatusLine()}')
  # buffer-local 按键：normal+insert 的 <CR>（design W5），y/n 权限
  win_execute(win, 'nnoremap <buffer> <CR> <ScriptCmd>agent_shell#render#SendInput()<CR>')
  win_execute(win, 'inoremap <buffer> <CR> <ScriptCmd>agent_shell#render#SendInput()<CR>')
  win_execute(win, 'nnoremap <buffer> y <ScriptCmd>agent_shell#session#PermAnswer(''allow_once'')<CR>')
  win_execute(win, 'nnoremap <buffer> n <ScriptCmd>agent_shell#session#PermAnswer(''reject_once'')<CR>')
  win_execute(win, 'nnoremap <buffer> d <ScriptCmd>agent_shell#diff#Review()<CR>')
  # M4 补全：completefunc（buffer-local，# 全局名）+ Tab 映射（W5 逃生口）
  win_execute(win, 'setlocal completefunc=agent_shell#complete#Input')
  if !exists('g:agent_shell_no_tab_map') || !g:agent_shell_no_tab_map
    win_execute(win, 'inoremap <buffer> <Tab> <ScriptCmd>agent_shell#complete#Tab()<CR>')
  endif
  # M5 steering：<M-CR>（normal + insert；终端兼容见 README 附录）
  win_execute(win, 'nnoremap <buffer> <M-CR> <ScriptCmd>agent_shell#render#SteerInput()<CR>')
  win_execute(win, 'inoremap <buffer> <M-CR> <ScriptCmd>agent_shell#render#SteerInput()<CR>')
  SetupHighlight(win)
enddef

# ---------- 高亮（design D4） ----------

def SetupHighlight(win: number)
  if exists('g:agent_shell_highlight') && !g:agent_shell_highlight
    return
  endif
  if win == -1
    return  # 无窗口时跳过（syntax 需窗口上下文）
  endif
  var hl: list<string> = [
    'You  Identifier', 'Steer Special', 'AI   String', 'TOOL Special', 'PLAN Statement',
    'PERM WarningMsg', 'ERR  ErrorMsg', 'USE  Comment', 'CMD  Comment',
    'ACP  Comment', 'Sep  NonText',
  ]
  win_execute(win, [
    'syntax match AgentShellYou  "^\[你]"',
    'syntax match AgentShellSteer "^\[你·STEER\]\|^\[STEER\]"',
    'syntax match AgentShellAI   "^\[AI]"',
    'syntax match AgentShellTOOL "^\[TOOL]"',
    'syntax match AgentShellPLAN "^\[PLAN]"',
    'syntax match AgentShellPERM "^\[PERM]"',
    'syntax match AgentShellERR  "^\[ERR]"',
    'syntax match AgentShellUSE  "^\[USE]"',
    'syntax match AgentShellCMD  "^\[CMD]"',
    'syntax match AgentShellACP  "^\[ACP]"',
    $'syntax match AgentShellSep  "^{SEPARATOR}"',
  ])
  for h in hl
    execute 'highlight default link AgentShell' .. h
  endfor
enddef

# ---------- busy（design D2；状态由 session 持有） ----------

# statusline 表达式入口（export 注册 # 全局名供 %{...} 引用）
export def StatusLine(): string
  if session.IsBusy()
    return BUSY_FRAMES[busy_frame_idx % len(BUSY_FRAMES)] .. ' agent working…' .. session.UsageBrief()
  endif
  return 'agent-shell' .. session.UsageBrief()
enddef

# session 在轮次起止时调用
export def NotifyBusyChanged()
  var b = bufnr(BUFNAME)
  if b == -1
    return
  endif
  if session.IsBusy()
    if busy_timer == 0 && bufwinnr(b) != -1
      busy_timer = timer_start(120, (t: number) => Tick(t), {repeat: -1})
    endif
  else
    BusyTeardown()
  endif
enddef

def BusyTeardown()
  if busy_timer != 0
    timer_stop(busy_timer)
    busy_timer = 0
  endif
  var b = bufnr(BUFNAME)
  var w = b == -1 ? -1 : bufwinnr(b)
  if w != -1
    win_execute(w, 'redrawstatus')
  endif
enddef

# timer tick：自检自灭（design W2）
def Tick(_: number)
  var b = bufnr(BUFNAME)
  if !session.IsBusy() || bufwinnr(b) == -1
    BusyTeardown()
    return
  endif
  busy_frame_idx += 1
  var w = bufwinnr(b)
  if w != -1
    win_execute(w, 'redrawstatus')
  endif
enddef

# 测试断言入口：当前帧字符
export def BusyFrame(): string
  return BUSY_FRAMES[busy_frame_idx % len(BUSY_FRAMES)]
enddef

