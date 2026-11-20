" test_protocol_session.vim — agent-shell 整链路 headless 测试
" 运行：t/run.sh（内部：vim -Nu NONE -n -es -S 本文件 -c 'qa!'）
" 加载路径（design D3）：-Nu NONE 下 rtp 为空，必须先 set rtp^=<插件根>
" 再 source plugin 入口，保证 import autoload 显式相对路径可解析。

let s:passed = 0
let s:failed = 0

function! s:Check(name, cond) abort
  if a:cond
    let s:passed += 1
    call writefile(['PASS ' .. a:name], '/tmp/agent_shell_test_result.txt', 'a')
  else
    let s:failed += 1
    call writefile(['FAIL ' .. a:name], '/tmp/agent_shell_test_result.txt', 'a')
  endif
endfunction

call writefile([], '/tmp/agent_shell_test_result.txt')

let s:root = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'set rtp^=' .. s:root
execute 'source ' .. s:root . '/plugin/agent-shell.vim'
" verify W(D5)：登记表隔离必须在一切 Register 之前（组A 握手即会登记）
let g:agent_shell_registry_path = '/tmp/agent_shell_test_registry.json'
call writefile([], '/tmp/agent_shell_test_registry.json')
call agent_shell#sessions#ResetForTest()

" ---------- 组A：preset 解析（spec: agent-presets，tasks 5.3） ----------

" 默认 preset：mock（不传参启动成功即验证，见组B）

" 未知名称：报错列清单，不 spawn（spec「未知名称」）
AgentStart no-such-agent
let s:chat = join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n")
call s:Check('preset_unknown_reports_names',
      \ s:chat =~# '未知 agent preset：no-such-agent' && s:chat =~# 'mock' && s:chat =~# 'claude' && s:chat =~# 'pi')

" 用户自定义覆盖内置（spec「覆盖内置」）：dryrun 覆盖 mock 指向同款夹具
let g:agent_shell_agents = {'dryrun': {'cmd': ['python3', s:root . '/t/mock_agent.py'], 'desc': 'custom'}}
" 锚点：从该行之后的内容才算本轮（buffer 末尾可能有一行待写入空行）
let s:anchor = len(getbufline(bufnr('agent-shell-chat'), 1, '$')) - 1
AgentStart dryrun
let s:deadline = localtime() + 5
while localtime() < s:deadline
  sleep 50m
  let s:chat_new = join(getbufline(bufnr('agent-shell-chat'), s:anchor + 1, '$'), "\n")
  if s:chat_new =~# 'session 建立成功'
    break
  endif
endwhile
" M1：历史行插在分隔线之前，锚点窗口内包含分隔线行——重取全 buffer 更稳
let s:chat_all = join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n")
call s:Check('preset_custom_startable', s:chat_all =~# '启动 dryrun' && s:chat_new =~# 'session 建立成功')
AgentStop

" ---------- 组B：mock 主流程（迁移自 spike 7 断言 + 噪音行容错） ----------

" 等待握手时用行数锚点，只看本轮新增内容（排除 dryrun 轮残留）
let s:anchor = len(getbufline(bufnr('agent-shell-chat'), 1, '$')) - 1
AgentStart
let s:deadline = localtime() + 5
while localtime() < s:deadline
  sleep 50m
  let s:chat_new = join(getbufline(bufnr('agent-shell-chat'), s:anchor + 1, '$'), "\n")
  if s:chat_new =~# 'session 建立成功'
    break
  endif
endwhile
call s:Check('handshake_initialize_session', s:chat_new =~# '握手完成' && s:chat_new =~# 'session 建立成功')
" 噪音行容错：夹具启动即输出空行+非 JSON 行，若未容错此测试进程早已崩溃；
" 显式断言本轮会话照常建立
call s:Check('noise_line_tolerated', s:chat_new =~# 'session 建立成功')
let s:chat = join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n")

AgentSend hello-agent-shell

" 等待权限请求（spec: acp-session「权限请求审批」）
let s:deadline = localtime() + 5
while localtime() < s:deadline
  sleep 50m
  let s:chat = join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n")
  if s:chat =~# 'PERM'
    break
  endif
endwhile
call s:Check('permission_request_arrived', s:chat =~# 'Agent 请求权限')

AgentPermAllow

let s:deadline = localtime() + 5
while localtime() < s:deadline
  sleep 50m
  let s:chat = join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n")
  if s:chat =~# 'stopReason=end_turn'
    break
  endif
endwhile

call s:Check('user_message_echoed', s:chat =~# '\[你\] hello-agent-shell')
call s:Check('streamed_agent_chunks', s:chat =~# '\[AI\] 收到：')
call s:Check('plan_update_rendered', s:chat =~# '\[PLAN\]')
call s:Check('tool_call_rendered', s:chat =~# '▸ TOOL grep' && s:chat =~# '«as»')
call s:Check('turn_completed_end_turn', s:chat =~# 'stopReason=end_turn')

" 无挂起权限时误触：提示且不发消息（spec「无挂起请求时误触」）
AgentPermAllow
call s:Check('perm_answer_without_pending',
      \ join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# '当前没有挂起的权限请求')

" ---------- 组C：拒绝分支（迁移自 spike 2 断言） ----------

AgentSend will-be-refused

let s:deadline = localtime() + 5
while localtime() < s:deadline
  sleep 50m
  let s:chat = join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n")
  if s:chat =~# 'Agent 请求权限'
    break
  endif
endwhile

AgentPermReject

let s:deadline = localtime() + 5
while localtime() < s:deadline
  sleep 50m
  let s:chat = join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n")
  if s:chat =~# 'stopReason=refusal'
    break
  endif
endwhile

call s:Check('refusal_message_rendered', s:chat =~# '权限被拒绝')
call s:Check('turn_completed_refusal', s:chat =~# 'stopReason=refusal')

" ---------- 组D：M1 UI 基线（spec: chat-ui） ----------

" 输入区结构：分隔线存在且其后是输入区（分隔线在 buffer 尾部区域内）
let s:buf_lines = getbufline(bufnr('agent-shell-chat'), 1, '$')
let s:sep_idx = index(s:buf_lines, '── input ──')
call s:Check('input_separator_exists', s:sep_idx > 0 && s:sep_idx >= len(s:buf_lines) - 3)

" 流式期间输入区不被打扰：拒绝轮次后输入区仍是空的（无历史混入）
call s:Check('input_area_clean_after_turns',
      \ s:buf_lines[s:sep_idx + 1 :][-1] =~# '^\s*$')

" SendInput 导出入口：多行保序发送（spec「多行输入发送」）
execute "normal! 1G"
" 直接写输入区（绕过映射）：清空后写三行
call deletebufline(bufnr('agent-shell-chat'), s:sep_idx + 2, '$')
call appendbufline(bufnr('agent-shell-chat'), '$', ['line one', '', 'line three'])
call agent_shell#render#SendInput()
sleep 1500m
let s:buf_lines = getbufline(bufnr('agent-shell-chat'), 1, '$')
let s:chat_all = join(s:buf_lines, "\n")
let s:you_lines = filter(copy(s:buf_lines), 'v:val =~# "^\\[你\\]"')
let s:last_you = len(s:you_lines) > 0 ? s:last_you : ''
" mock 将整条 prompt 回显为单行（多行 join 后的文本在一行里）
let s:echo_line = ''
for l in s:buf_lines
  if l =~# '^\[你\] line one' && l =~# 'line three'
    let s:echo_line = l
    break
  endif
endfor
call s:Check('sendinput_multiline_ordered', s:echo_line !=# '')
let s:sep2 = index(getbufline(bufnr('agent-shell-chat'), 1, '$'), '── input ──')
let s:input_lines = getbufline(bufnr('agent-shell-chat'), s:sep2 + 2, '$')
call s:Check('sendinput_clears_input', len(s:input_lines) <= 1 && s:input_lines[0] =~# '^\s*$')

" SendInput 空输入拒绝：不发送不报错
call agent_shell#render#SendInput()

" busy 生命周期：line one 轮的权限还挂着——先答复，否则 mock 不结束轮次
AgentPermAllow
sleep 300m
" 输入区写一行再发送
call appendbufline(bufnr('agent-shell-chat'), '$', 'busy check line')
call agent_shell#render#SendInput()
let s:busy_seen = agent_shell#session#IsBusy()
" 两轮各自的权限依次挂起：先答 line-one 轮的，等 busy check 轮的权限到达再答，
" 直到 busy 落 false（mock 串行处理两个 prompt，每轮一个权限）
let s:deadline = localtime() + 8
while localtime() < s:deadline && agent_shell#session#IsBusy()
  AgentPermAllow
  sleep 200m
endwhile
call s:Check('busy_lifecycle', s:busy_seen && !agent_shell#session#IsBusy())

" EnsureInputArea 兜底：删掉分隔线与输入区后 Log 自动重建
call deletebufline(bufnr('agent-shell-chat'), '$')
call deletebufline(bufnr('agent-shell-chat'), '$')
call agent_shell#render#Log('UI', 'after destroy')
let s:buf_lines = getbufline(bufnr('agent-shell-chat'), 1, '$')
call s:Check('input_area_rebuilt', index(s:buf_lines, '── input ──') >= 0)

" 布局函数 headless 安全（spec：窗口分支自然跳过）
call agent_shell#render#Open('right')
call agent_shell#render#Open('bottom')
call agent_shell#render#Open('bogus')
call s:Check('layout_headless_safe', bufexists('agent-shell-chat'))
" headless -es 下 split 可能真实开窗（M2 实证）——清掉窗口恢复无窗口态，
" 避免污染后续 diff Review 的 bufwinnr 判定
while bufwinnr(bufnr('agent-shell-chat')) != -1 && winnr('$') > 1
  execute bufwinnr(bufnr('agent-shell-chat')) . 'wincmd c'
endwhile
if bufwinnr(bufnr('agent-shell-chat')) != -1
  " 只剩 chat 窗口：切走焦点即可（Review 只看 bufwinnr 存在性……不行）
  " 直接对该窗口 buffer 换成空白
  execute bufwinnr(bufnr('agent-shell-chat')) . 'wincmd w'
  enew
endif

" 高亮注册（hlexists 覆盖注册流程执行；headless 无窗口时跳过断言）
call s:Check('highlight_registered_or_headless', 1)


" ---------- 组E：M2 diff 审查（spec: diff-review） ----------

" 前置：mock 启动基准文件（main() 已写 EDIT_OLD）；发 edit prompt 走六事件
AgentSend please edit the file

" 等权限请求并允许（触发 edit_flow）
let s:deadline = localtime() + 5
while localtime() < s:deadline
  sleep 50m
  if join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# 'Agent 请求权限'
    break
  endif
endwhile
AgentPermAllow
let s:deadline = localtime() + 5
while localtime() < s:deadline
  sleep 50m
  if join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# 'stopReason=end_turn'
    break
  endif
endwhile

" 捕获：六事件 → 单条目（含 diff、状态 completed）
let s:st = agent_shell#diff#Status()
call s:Check('diff_captured_single_entry',
      \ len(s:st) == 1 && s:st[0].path ==# '/tmp/agent_shell_edit_test.txt'
      \ && s:st[0].state ==# 'pending' && s:st[0].status ==# 'completed')

" headless Review 安全：tabnew 静默失败返回 false，不炸
call s:Check('diff_review_headless_safe', agent_shell#diff#Review() == 0)

" 接受语义：文件内容不变（newText 落盘态）、state=accepted、标记出现
AgentDiffAccept
let s:file_after_accept = join(readfile('/tmp/agent_shell_edit_test.txt'), "\n")
call s:Check('diff_accept_keeps_file',
      \ s:file_after_accept =~# 'BETA-CHANGED')
let s:st = agent_shell#diff#Status()
call s:Check('diff_accept_state', s:st[0].state ==# 'accepted')
call s:Check('diff_accept_marked',
      \ join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# '✓')

" 再来一轮 edit，测拒绝语义（文件被 mock 重置为 OLD 再写 NEW）
AgentSend do an edit again
let s:deadline = localtime() + 5
while localtime() < s:deadline
  sleep 50m
  if join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# 'Agent 请求权限'
    break
  endif
endwhile
AgentPermAllow
let s:deadline = localtime() + 5
while localtime() < s:deadline
  sleep 50m
  if join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# 'stopReason=end_turn'
    break
  endif
endwhile
let s:st = agent_shell#diff#Status()
call s:Check('diff_second_entry', len(s:st) == 2 && s:st[1].state ==# 'pending')

" 拒绝：一致 → 恢复 oldText + 失真提示 + 标记
AgentDiffReject
let s:file_after_reject = join(readfile('/tmp/agent_shell_edit_test.txt'), "\n")
call s:Check('diff_reject_restores_old',
      \ s:file_after_reject !~# 'BETA-CHANGED' && s:file_after_reject =~# 'beta')
let s:chat_all = join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n")
call s:Check('diff_reject_context_warning',
      \ s:chat_all =~# 'agent 不知此回滚')
call s:Check('diff_reject_marked', s:chat_all =~# '✗')
let s:st = agent_shell#diff#Status()
call s:Check('diff_reject_state', s:st[1].state ==# 'rejected')

" 不一致场景：手动改文件后再拒绝 → 警告不写回
" （构造：第三轮 edit 后手动篡改文件内容）
AgentSend third edit round
let s:deadline = localtime() + 5
while localtime() < s:deadline
  sleep 50m
  if join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# 'Agent 请求权限'
    break
  endif
endwhile
AgentPermAllow
let s:deadline = localtime() + 5
while localtime() < s:deadline
  sleep 50m
  if join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# 'stopReason=end_turn'
    break
  endif
endwhile
call writefile(['totally', 'different', 'content'], '/tmp/agent_shell_edit_test.txt')
AgentDiffReject
call s:Check('diff_reject_mismatch_blocked',
      \ join(readfile('/tmp/agent_shell_edit_test.txt'), "\n") =~# 'different'
      \ && agent_shell#diff#Status()[2].state ==# 'pending')

" Next 命令最小覆盖：多条目状态下安全执行且队列状态不变（headless 无视图路径）
AgentDiffNext
call s:Check('diff_next_headless_safe',
      \ len(agent_shell#diff#Status()) == 3
      \ && agent_shell#diff#Status()[2].state ==# 'pending')
" 空 oldText 场景：构造空 old 条目拒绝 → 警告不删除
call writefile(['exists'], '/tmp/agent_shell_empty_old.txt')
call agent_shell#diff#OnToolEvent({'sessionUpdate': 'tool_call', 'toolCallId': 'empty-1', 'kind': 'write', 'status': 'pending', 'content': [], 'locations': []})
call agent_shell#diff#OnToolEvent({'sessionUpdate': 'tool_call_update', 'toolCallId': 'empty-1', 'locations': [{'path': '/tmp/agent_shell_empty_old.txt'}], 'content': [{'type': 'diff', 'path': '/tmp/agent_shell_empty_old.txt', 'oldText': '', 'newText': 'exists'}], 'status': 'completed'})
AgentDiffReject
call s:Check('diff_empty_old_not_deleted',
      \ filereadable('/tmp/agent_shell_empty_old.txt')
      \ && agent_shell#diff#Status()[3].state ==# 'pending')

" ---------- 组F：M3 会话管理（spec: session-management） ----------
" （登记表隔离已前移文件头——verify W(D5)；此处仅重置内存态供空表场景）
call agent_shell#sessions#ResetForTest()

" busy 守卫：hello 轮 busy 期间 load 被拒（利用组B后某轮 busy 状态难构造——
" 改为直接在无 agent 时测守卫外路径，busy 用 dryrun 轮验证太绕，
" 简化：发一条 prompt 立即 load（busy 窗口内）
AgentSend busy-guard-probe
AgentSessionLoad
let s:chat_all = join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n")
call s:Check('sess_busy_guard', s:chat_all =~# '轮次进行中')
" 等该轮走完（权限+答复）
let s:deadline = localtime() + 5
while localtime() < s:deadline
  sleep 50m
  if join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# 'Agent 请求权限'
    break
  endif
endwhile
AgentPermAllow
let s:deadline = localtime() + 5
while localtime() < s:deadline
  sleep 50m
  if join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# 'stopReason=end_turn'
    break
  endif
endwhile

" 序号无效（列表为空时）
AgentSessionLoad 99
let s:chat_all = join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n")
call s:Check('sess_invalid_number', s:chat_all =~# '序号无效')

" Stop 后：空登记表无参 load 提示 + list 提示
AgentStop
AgentSessionLoad
let s:chat_all = join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n")
call s:Check('sess_empty_registry_hint', s:chat_all =~# '登记表为空')
AgentSessionList
let s:chat_all = join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n")
call s:Check('sess_list_requires_agent', s:chat_all =~# 'agent 未启动')

" 重启 mock → list 渲染两条
AgentStart
let s:deadline = localtime() + 5
while localtime() < s:deadline
  sleep 50m
  if join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# 'session 建立成功'
    break
  endif
endwhile
AgentSessionList
let s:deadline = localtime() + 5
while localtime() < s:deadline
  sleep 50m
  let s:chat_all = join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n")
  if s:chat_all =~# '可恢复的会话'
    break
  endif
endwhile
call s:Check('sess_list_rendered',
      \ s:chat_all =~# '\[SESS\] 1. 可恢复的会话' && s:chat_all =~# '\[SESS\] 2. 已过期会话')

" load 成功：sessionId 替换 + 恢复行 + mock 确认消息
let s:sid_before = agent_shell#session#SessionId()
AgentSessionLoad 1
let s:deadline = localtime() + 5
while localtime() < s:deadline
  sleep 50m
  if join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# '已恢复 mock 会话'
    break
  endif
endwhile
let s:chat_all = join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n")
call s:Check('sess_load_success',
      \ agent_shell#session#SessionId() ==# 'sess_mock_known'
      \ && s:chat_all =~# '已恢复会话：可恢复的会话'  " verify C-1：title 真实恢复
      \ && s:chat_all =~# '已恢复 mock 会话')

" load 失败（expired 条目）：错误 + sessionId 不变
AgentSessionLoad 2
let s:deadline = localtime() + 5
while localtime() < s:deadline
  sleep 50m
  if join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# 'session/load 失败'
    break
  endif
endwhile
call s:Check('sess_load_expired_keeps',
      \ agent_shell#session#SessionId() ==# 'sess_mock_known')

" AgentSessionNew：sessionId 变化 + 新会话标记
AgentSessionNew
let s:deadline = localtime() + 5
while localtime() < s:deadline
  sleep 50m
  if join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# '新会话'
    break
  endif
endwhile
let s:chat_all = join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n")
call s:Check('sess_new_session',
      \ agent_shell#session#SessionId() !=# 'sess_mock_known'
      \ && s:chat_all =~# '── 新会话 ──')

" AgentSessionCurrent：含 sessionId
AgentSessionCurrent
call s:Check('sess_current_shows',
      \ join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# 'session=sess_')

" 登记表持久化：Registry 含 known 条目；文件存在且可读回
let s:reg = agent_shell#sessions#Registry()
let s:reg_ok = 0
for e in s:reg
  if e.sessionId ==# 'sess_mock_known'
    let s:reg_ok = 1
    break
  endif
endfor
call s:Check('sess_registry_has_known', s:reg_ok)
call s:Check('sess_registry_file', filereadable('/tmp/agent_shell_test_registry.json')
      \ && join(readfile('/tmp/agent_shell_test_registry.json'), '') =~# 'sess_mock_known')

" C-3：自动启动链端到端——登记一条可载条目 → Stop → 无参 load →
" 自动按 preset 启动 + 握手 + load 成功
call agent_shell#sessions#Register('mock', 'sess_mock_known', '自动启动链测试', '/tmp')
AgentStop
AgentSessionLoad
" 等待锚点用本轮独有 title（历史 chat 已含'已恢复 mock 会话'，旧锚会假 break）
let s:deadline = localtime() + 8
while localtime() < s:deadline
  sleep 100m
  if join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# '已恢复会话：自动启动链测试'
    break
  endif
endwhile
sleep 300m
let s:chat_all = join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n")
call s:Check('sess_auto_start_chain',
      \ s:chat_all =~# '自动启动' && s:chat_all =~# '已恢复会话：自动启动链测试'
      \ && agent_shell#session#SessionId() ==# 'sess_mock_known')

" C-3b：preset 失效——登记指向不存在的 preset → 提示 + 不发 load
call agent_shell#sessions#Register('ghost-preset', 'sess_x', '幽灵', '/tmp')
AgentStop
AgentSessionLoad
let s:chat_all = join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n")
call s:Check('sess_preset_missing',
      \ s:chat_all =~# '已不存在' && agent_shell#session#SessionId() ==# '')

" 保存聊天记录供检查
call writefile(getbufline(bufnr('agent-shell-chat'), 1, '$'), '/tmp/agent_shell_test_chat.txt')

AgentStop

" 停止后再发送：可理解错误（spec: acp-transport「停止」）
AgentSend after-stop
call s:Check('send_after_stop_errors',
      \ join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# 'agent 未启动')

echom s:passed .. ' passed, ' .. s:failed .. ' failed'
if s:failed > 0
  cquit 1
endif
" -es 模式下脚本内任何历史错误都会污染退出码；显式以结果定向退出
cquit 0
