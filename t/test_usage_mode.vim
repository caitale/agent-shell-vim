" test_usage_mode.vim — MOCK_USAGE_MODE=used_only 降级场景
" 用法：MOCK_USAGE_MODE=used_only vim -Nu NONE -n -es -S t/test_usage_mode.vim -c 'qa!'
let s:passed = 0
let s:failed = 0
function! s:Check(name, cond) abort
  if a:cond
    let s:passed += 1
    call writefile(['PASS ' . a:name], '/tmp/agent_shell_usage_mode_result.txt', 'a')
  else
    let s:failed += 1
    call writefile(['FAIL ' . a:name], '/tmp/agent_shell_usage_mode_result.txt', 'a')
  endif
endfunction
call writefile([], '/tmp/agent_shell_usage_mode_result.txt')

let s:root = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'set rtp^=' .. s:root
execute 'source ' . s:root . '/plugin/agent-shell.vim'
let g:agent_shell_registry_path = '/tmp/as_usage_reg.json'
call agent_shell#sessions#ResetForTest()

AgentStart
let s:d = localtime() + 5
while localtime() < s:d
  sleep 50m
  if join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# 'session 建立成功'
    break
  endif
endwhile
AgentSend usage-degrade-probe
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
AgentUsage
let s:chat = join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n")
call s:Check('usage_used_only_total',
      \ s:chat =~# '累计 total=300（总量口径')
AgentStop
qa!
