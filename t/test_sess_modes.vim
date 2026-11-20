" test_sess_modes.vim — MOCK_SESS_MODE 子进程场景（empty/paged）
" 用法：MOCK_SESS_MODE=empty vim -Nu NONE -n -es -S t/test_sess_modes.vim -c 'qa!'
" 判定：/tmp/agent_shell_sess_mode_result.txt
let s:passed = 0
let s:failed = 0
function! s:Check(name, cond) abort
  if a:cond
    let s:passed += 1
    call writefile(['PASS ' . a:name], '/tmp/agent_shell_sess_mode_result.txt', 'a')
  else
    let s:failed += 1
    call writefile(['FAIL ' . a:name], '/tmp/agent_shell_sess_mode_result.txt', 'a')
  endif
endfunction

call writefile([], '/tmp/agent_shell_sess_mode_result.txt')
let s:mode = exists('$MOCK_SESS_MODE') ? $MOCK_SESS_MODE : ''

let s:root = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'set rtp^=' .. s:root
execute 'source ' . s:root . '/plugin/agent-shell.vim'
let g:agent_shell_registry_path = '/tmp/agent_shell_mode_registry.json'
call agent_shell#sessions#ResetForTest()

AgentStart
let s:d = localtime() + 5
while localtime() < s:d
  sleep 50m
  if join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# 'session 建立成功'
    break
  endif
endwhile
AgentSessionList
let s:d = localtime() + 5
while localtime() < s:d
  sleep 50m
  let s:chat = join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n")
  if s:chat =~# '无历史会话\|会话列表'
    sleep 300m
    break
  endif
endwhile
let s:chat = join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n")

if s:mode ==# 'empty'
  call s:Check('sess_mode_empty_hint', s:chat =~# '无历史会话')
elseif s:mode ==# 'paged'
  " 两页合并：两条不同 title 都出现
  call s:Check('sess_mode_paged_merged',
        \ s:chat =~# '分页第一条' && s:chat =~# '第二页会话')
else
  call s:Check('sess_mode_unknown', 0)
endif

AgentStop
qa!
