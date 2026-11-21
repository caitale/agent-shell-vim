" test_no_modes.vim — MOCK_NO_MODES=1 模式降级场景
let s:passed = 0
let s:failed = 0
function! s:Check(name, cond) abort
  if a:cond
    let s:passed += 1
    call writefile(['PASS ' . a:name], '/tmp/as_no_modes_result.txt', 'a')
  else
    let s:failed += 1
    call writefile(['FAIL ' . a:name], '/tmp/as_no_modes_result.txt', 'a')
  endif
endfunction
call writefile([], '/tmp/as_no_modes_result.txt')
let s:root = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'set rtp^=' .. s:root
execute 'source ' .. s:root . '/plugin/agent-shell.vim'
let g:agent_shell_registry_path = '/tmp/as_nm_reg.json'
call agent_shell#sessions#ResetForTest()
AgentStart
let s:d = localtime() + 5
while localtime() < s:d
  sleep 50m
  if join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# 'session 建立成功'
    break
  endif
endwhile
AgentMode
let s:chat = join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n")
call s:Check('mode_no_modes_degrade', s:chat =~# '当前 agent 未提供模式列表')
AgentStop
qa!
