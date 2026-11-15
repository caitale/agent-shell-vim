vim9script
# diff.vim — 结构化 diff 捕获、审查队列、vimdiff 编排、接受/拒绝
#
# wire 契约（design「wire 契约」小节，claude-agent-acp 实测 2026-11-14）：
#   tool_call(pending) → tool_call_update(locations) → tool_call_update(rawInput)
#   → tool_call_update(content=[{type:'diff',path,oldText,newText}])
#   → tool_call_update(status=completed)
# 解析只依赖 ACP 标准字段（content[].type/locations/status），不碰 _meta 扩展。
#
# 依赖方向（design D1）：session → diff → render。审查动作不影响协议流。

import autoload './render.vim'

var pending: list<dict<any>> = []
# {id, path, old_text, new_text, state: 'pending'|'accepted'|'rejected',
#  title, status, kind, block_id}

var active_idx = -1       # 当前审查项（Review 设定；操作后清除）
var review_bufs: list<number> = []   # 审查映射注册过的 buffer（Teardown 清理）
var review_tab = 0        # 审查 tab 号（0 = 无）

# ---------- 捕获（session 转发 tool_call 与 tool_call_update） ----------

export def OnToolEvent(upd: dict<any>)
  var id = upd->get('toolCallId', '')
  if id ==# ''
    return
  endif
  var entry = FindById(id)
  var is_new = empty(entry)
  if is_new
    entry = {
      id: id,
      path: '',
      old_text: '',
      new_text: '',
      state: 'pending',
      title: upd->get('title', ''),
      status: upd->get('status', ''),
      kind: upd->get('kind', ''),
      block_id: 0,
    }
  endif

  # 状态同步（completed 在 tool_call_update 上）
  if upd->has_key('status')
    entry['status'] = upd['status']
  endif
  # 标题演进（pending "Edit" → "Edit probe_target.txt"，仅展示用）
  var t = upd->get('title', '')
  if t !=# '' && t !=# entry['title']
    entry['title'] = t
  endif

  # path 兜底链：diff content.path → locations[0].path → rawInput.file_path
  var path = entry['path']
  if path ==# ''
    var locs = upd->get('locations', [])
    if type(locs) == v:t_list && len(locs) > 0 && type(locs[0]) == v:t_dict
      path = locs[0]->get('path', '')
    endif
  endif
  if path ==# ''
    var raw = upd->get('rawInput', {})
    if type(raw) == v:t_dict
      path = raw->get('file_path', raw->get('path', ''))
    endif
  endif
  # 结构化 diff 提取（content[].type == 'diff'，首见即定不覆盖）
  var content = upd->get('content', [])
  if type(content) == v:t_list
    for c in content
      if type(c) == v:t_dict && c->get('type', '') ==# 'diff'
        if entry['old_text'] ==# '' && entry['new_text'] ==# ''
          entry['old_text'] = c->get('oldText', '')
          entry['new_text'] = c->get('newText', '')
        endif
        if c->get('path', '') !=# ''
          path = c['path']  # diff 自带 path 最权威
        endif
      endif
    endfor
  endif
  if path !=# ''
    entry['path'] = path
  endif

  if is_new
    # 入审查队列条件：edit/write 类（diff 后续填充），或事件直接带 diff
    var has_diff = entry['old_text'] !=# '' || entry['new_text'] !=# ''
    if entry['kind'] ==# 'edit' || entry['kind'] ==# 'write' || has_diff
      if entry['path'] !=# '' || has_diff
        add(pending, entry)
      endif
    endif
    # 其余（execute/read 且无 diff）：不入队（render 照常渲染）
  endif

  # completed + auto：有窗口才弹（headless bufwinnr 恒 -1）
  if entry['status'] ==# 'completed' && entry->get('auto_fired', false) == false
        && HasDiffEntry(entry) && AutoEnabled()
    entry['auto_fired'] = true
    var chat = bufnr('agent-shell-chat')
    if chat != -1 && bufwinnr(chat) != -1
      Review(IndexOf(entry))
    endif
  endif
enddef

def FindById(id: string): dict<any>
  for e in pending
    if e['id'] ==# id
      return e
    endif
  endfor
  return {}
enddef

def IndexOf(entry: dict<any>): number
  return index(pending, entry)
enddef

def HasDiffEntry(e: dict<any>): bool
  return e['old_text'] !=# '' || e['new_text'] !=# ''
enddef

def AutoEnabled(): bool
  return exists('g:agent_shell_diff_auto') && g:agent_shell_diff_auto
enddef

def ChainEnabled(): bool
  return exists('g:agent_shell_diff_chain') && g:agent_shell_diff_chain
enddef

# ---------- 队列查询 ----------

export def Status(): list<dict<any>>
  var out: list<dict<any>> = []
  for e in pending
    add(out, {
      'id': e['id'],
      'path': e['path'],
      'state': e['state'],
      'status': e['status'],
    })
  endfor
  return out
enddef

def FirstPending(): number
  for i in range(len(pending))
    if pending[i]['state'] ==# 'pending'
      return i
    endif
  endfor
  return -1
enddef

# ---------- 审查编排（design D3 严格顺序） ----------

export def Review(idx: number = -1): bool
  var i = idx >= 0 && idx < len(pending) ? idx : FirstPending()
  if i < 0
    render.Log('DIFF', '没有待审查的改动')
    return false
  endif
  var entry = pending[i]
  if !HasDiffEntry(entry) || entry['path'] ==# ''
    render.Log('DIFF', $'该条目无结构化 diff（{entry["title"]}），跳过')
    return false
  endif

  # headless 判定：聊天 buffer 无窗口时不开审查视图（tabnew 在 -es 下其实
  # 能建 tab——实证；真正该判的是"用户看得到"）。无窗口直接走命令路径。
  var chat = bufnr('agent-shell-chat')
  if chat == -1 || bufwinnr(chat) == -1
    return false
  endif
  var before_tabs = tabpagenr('$')
  execute 'tabnew'
  if tabpagenr('$') == before_tabs
    return false
  endif
  review_tab = tabpagenr()

  # 右侧：目标文件。已打开的 buffer 先刷新（防 stale）；modified 警告降级
  var filebuf = bufnr(entry['path'])
  if filebuf != -1
    if getbufvar(filebuf, '&modified')
      render.Log('DIFF', $'警告：{entry["path"]} 有未保存修改，审查视图可能非最新')
    else
      execute $'buffer {filebuf}'
      checktime
    endif
  else
    execute 'edit ' .. fnameescape(entry['path'])
  endif
  var right_buf = bufnr('%')

  # 左侧：oldText 只读临时 buffer（先写内容再锁定——顺序反了会 E21）
  var oldname = 'agent-shell-diff-old://' .. entry['id']
  execute $'vnew {fnameescape(oldname)}'
  setlocal buftype=nofile
  setlocal bufhidden=wipe
  var lines = split(entry['old_text'], "\n")
  if !empty(lines)
    if line('$') == 1 && getline(1) ==# ''
      deletebufline(bufnr(oldname), 1)
    endif
    appendbufline(bufnr(oldname), '$', lines)
  endif
  setlocal nomodifiable

  # diff 模式：左右两侧
  execute 'normal! h'
  diffthis
  execute 'normal! l'
  diffthis

  # 映射注册：左右两 buffer（记录清单，Teardown 清理）
  review_bufs = [bufnr(oldname), right_buf]
  RegisterKeys(right_buf)
  RegisterKeys(bufnr(oldname))

  active_idx = i
  render.MarkToolCall(entry['id'], 'reviewing')
  return true
enddef

def RegisterKeys(b: number)
  # 经全局名转发（E1013 范式：映射内只用全局符号）
  var buf_save = bufnr('%')
  execute $'{b}buffer!'
  nnoremap <buffer> ]a <ScriptCmd>agent_shell#diff#Accept()<CR>
  nnoremap <buffer> ]r <ScriptCmd>agent_shell#diff#Reject()<CR>
  nnoremap <buffer> ]n <ScriptCmd>agent_shell#diff#Next()<CR>
  execute $'{buf_save}buffer!'
enddef

def Teardown()
  # 清映射（用户 buffer 不残留）→ 关审查 tab → 回聊天窗
  for b in review_bufs
    if bufexists(b)
      try
        execute $'nunmap <buffer> ]a'
      catch
      endtry
      try
        execute $'nunmap <buffer> ]r'
      catch
      endtry
      try
        execute $'nunmap <buffer> ]n'
      catch
      endtry
    endif
  endfor
  review_bufs = []
  if review_tab > 0 && review_tab <= tabpagenr('$')
    execute $'{review_tab}tabclose'
  endif
  review_tab = 0
  var chat = bufnr('agent-shell-chat')
  if chat != -1
    var w = bufwinnr(chat)
    if w != -1
      execute $'{w}wincmd w'
    endif
  endif
enddef

# ---------- 接受 / 拒绝（design D4） ----------

export def Accept()
  var i = active_idx >= 0 ? active_idx : FirstPending()
  if i < 0
    render.Log('DIFF', '没有待审查的改动')
    return
  endif
  var entry = pending[i]
  entry['state'] = 'accepted'
  render.MarkToolCall(entry['id'], 'accepted')
  Teardown()
  active_idx = -1
  render.Log('DIFF', $'已接受：{entry["path"]}')
  if ChainEnabled()
    Review()
  endif
enddef

export def Reject()
  var i = active_idx >= 0 ? active_idx : FirstPending()
  if i < 0
    render.Log('DIFF', '没有待审查的改动')
    return
  endif
  var entry = pending[i]

  if entry['old_text'] ==# ''
    render.Log('DIFF', $'警告：{entry["path"]} 为新建文件（oldText 为空），不做删除，请人工处理')
    return
  endif

  # Norm 规范化比对：文件当前内容 vs newText
  var cur = ''
  try
    cur = join(readfile(entry['path']), "\n")
  catch
    render.Log('DIFF', $'警告：无法读取 {entry["path"]}，保持待审查')
    return
  endtry
  var norm_cur = Norm(cur)
  var norm_new = Norm(entry['new_text'])
  if norm_cur !=# norm_new
    render.Log('DIFF', $'警告：{entry["path"]} 当前内容与 newText 不一致（agent 落盘失败或已被修改），不写回；请人工处理')
    return
  endif

  # 一致 → 恢复 oldText（writefile 直写，绕开 undo）
  try
    writefile(split(entry['old_text'], "\n"), entry['path'])
  catch
    render.Log('DIFF', $'写回失败：{v:exception}')
    return
  endtry
  # 已打开 buffer 刷新（modified 降级为警告）
  var fb = bufnr(entry['path'])
  if fb != -1
    if getbufvar(fb, '&modified')
      render.Log('DIFF', $'提示：{entry["path"]} 的打开 buffer 有未保存修改，未强制刷新')
    else
      var w = bufwinnr(fb)
      if w != -1
        win_execute(w, 'checktime')
      endif
    endif
  endif

  entry['state'] = 'rejected'
  render.MarkToolCall(entry['id'], 'rejected')
  Teardown()
  active_idx = -1
  render.Log('DIFF', $'已拒绝并恢复：{entry["path"]}（agent 不知此回滚，下轮请告知）')
  if ChainEnabled()
    Review()
  endif
enddef

def Norm(s: string): string
  var lines = split(s, "\n")
  # 去首尾空行（与 readfile/writefile 的末尾换行语义对齐）
  while len(lines) > 0 && lines[0] =~# '^\s*$'
    remove(lines, 0)
  endwhile
  while len(lines) > 0 && lines[-1] =~# '^\s*$'
    remove(lines, -1)
  endwhile
  return join(lines, "\n")
enddef

export def Next()
  if active_idx >= 0
    # 当前项未决（pending）——审查完才走 Teardown？Next 语义：跳到下一 pending
    Teardown()
    active_idx = -1
  endif
  Review()
enddef
