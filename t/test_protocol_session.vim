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
call s:Check('preset_custom_startable', s:chat_new =~# '启动 dryrun' && s:chat_new =~# 'session 建立成功')
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
call s:Check('tool_call_rendered', s:chat =~# '\[TOOL\] grep')
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
qa!
