" test_stream_mode.vim — MOCK_STREAM_MODE=token token 级流式场景
" 钉住 2026-11-22 修复：pi 真实 token 级 chunk 必须拼接渲染成完整行，
" 而非逐 chunk 独立成行（曾致数百行 [AI] 碎屏）。
" 用法：MOCK_STREAM_MODE=token vim -Nu NONE -n -es -S t/test_stream_mode.vim -c 'qa!'
let s:passed = 0
let s:failed = 0
function! s:Check(name, cond) abort
  if a:cond
    let s:passed += 1
    call writefile(['PASS ' . a:name], '/tmp/as_stream_mode_result.txt', 'a')
  else
    let s:failed += 1
    call writefile(['FAIL ' . a:name], '/tmp/as_stream_mode_result.txt', 'a')
  endif
endfunction
call writefile([], '/tmp/as_stream_mode_result.txt')

let s:root = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'set rtp^=' .. s:root
execute 'source ' . s:root . '/plugin/agent-shell.vim'
let g:agent_shell_registry_path = '/tmp/as_stream_reg.json'
call agent_shell#sessions#ResetForTest()

AgentStart
let s:d = localtime() + 5
while localtime() < s:d
  sleep 50m
  if join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# 'session 建立成功'
    break
  endif
endwhile

AgentSend token-stream-probe
let s:d = localtime() + 6
while localtime() < s:d
  sleep 100m
  if join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# 'Agent 请求权限'
    break
  endif
endwhile
AgentPermAllow
let s:d = localtime() + 6
while localtime() < s:d
  sleep 100m
  if join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# 'stopReason=end_turn'
    break
  endif
endwhile

" 逐行检查：token 级 chunk 必须拼成完整句子（单行），不得碎成多行
let s:chat_lines = getbufline(bufnr('agent-shell-chat'), 1, '$')
let s:expected = '[AI] 收到：「token-stream-probe」。这是一段流式输出，由 mock-agent 分多个 chunk 发出。'
call s:Check('token_stream_single_line',
      \ index(s:chat_lines, s:expected) >= 0)
" 碎屏回归防护：不允许出现裸单字符 AI 行（旧 bug 特征：'[AI] ' + 1 字符）
let s:frag_lines = filter(copy(s:chat_lines), 'v:val =~# ''^\[AI\] .\{1,2\}$''')
call s:Check('token_stream_no_fragments', empty(s:frag_lines))
" 多轮次隔离：第二个流式块起新块（不拼接上一轮残留）
AgentSend second-turn-probe
let s:d = localtime() + 6
while localtime() < s:d
  sleep 100m
  if join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# 'Agent 请求权限'
    break
  endif
endwhile
AgentPermAllow
let s:d = localtime() + 6
while localtime() < s:d
  sleep 100m
  let s:chat2 = join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n")
  if s:chat2 =~# 'stopReason=end_turn' && s:chat2 =~# 'second-turn-probe'
    break
  endif
endwhile
let s:expected2 = '[AI] 收到：「second-turn-probe」。这是一段流式输出，由 mock-agent 分多个 chunk 发出。'
call s:Check('token_stream_second_turn_new_block',
      \ index(getbufline(bufnr('agent-shell-chat'), 1, '$'), s:expected2) >= 0)

AgentStop
qa!
