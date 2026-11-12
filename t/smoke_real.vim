" smoke_real.vim — 真实 agent 手动冒烟（不进 CI，需消耗 token）
" 用法：
"   vim -Nu NONE -n -es -c 'let g:agent_shell_smoke = "claude"' -S t/smoke_real.vim -c 'qa!'
"   vim -Nu NONE -n -es -c 'let g:agent_shell_smoke = "pi"'     -S t/smoke_real.vim -c 'qa!'
" 前置：
"   claude: npm i -g @agentclientprotocol/claude-agent-acp（已登录）
"   pi:     npm i -g @geohar/pi-acp；NODE_OPTIONS shim 环境需在 vimrc 中
"           let g:agent_shell_agents = {'pi': {'cmd': ['env','-u','NODE_OPTIONS','pi-acp'], 'desc': 'pi (clean env)'}}
" 断言：握手建会话、单轮文本问答（pong）、end_turn

let s:passed = 0
let s:failed = 0

function! s:Check(name, cond) abort
  if a:cond
    let s:passed += 1
    call writefile(['PASS ' .. a:name], '/tmp/agent_shell_smoke_result.txt', 'a')
  else
    let s:failed += 1
    call writefile(['FAIL ' .. a:name], '/tmp/agent_shell_smoke_result.txt', 'a')
  endif
endfunction

call writefile([], '/tmp/agent_shell_smoke_result.txt')

let s:preset = exists('g:agent_shell_smoke') ? g:agent_shell_smoke : 'claude'
let s:root = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'set rtp^=' .. s:root
execute 'source ' .. s:root . '/plugin/agent-shell.vim'

execute 'AgentStart ' . s:preset

" 握手（node 启动慢，60s）
let s:anchor = 0
let s:chat_new = ''
let s:deadline = localtime() + 60
while localtime() < s:deadline
  sleep 200m
  let s:chat_new = join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n")
  if s:chat_new =~# 'session 建立成功'
    break
  endif
endwhile
call s:Check('handshake_session_new', s:chat_new =~# 'session 建立成功')

AgentSend reply with exactly the word: pong

" 单轮问答（真实模型，120s）
let s:deadline = localtime() + 120
while localtime() < s:deadline
  sleep 300m
  let s:chat_new = join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n")
  if s:chat_new =~# 'stopReason=end_turn'
    break
  endif
endwhile

call s:Check('agent_replied_pong', s:chat_new =~# '\[AI\].*pong')
call s:Check('turn_end', s:chat_new =~# 'stopReason=end_turn')

call writefile(getbufline(bufnr('agent-shell-chat'), 1, '$'), '/tmp/agent_shell_smoke_chat.txt')

AgentStop

echom s:passed .. ' passed, ' .. s:failed .. ' failed'
if s:failed > 0
  cquit 1
endif
qa!
