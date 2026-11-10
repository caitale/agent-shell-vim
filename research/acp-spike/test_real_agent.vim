" test_real_agent.vim — 真实 agent（claude-agent-acp）冒烟测试
" 前置：npm install -g @agentclientprotocol/claude-agent-acp，且已完成 claude 登录
" 运行：vim -Nu NONE -n -es -S test_real_agent.vim -c 'qa!'
" 断言：握手返回 agentInfo、session 建立、单轮 prompt 得到 end_turn 回复

let s:passed = 0
let s:failed = 0

function! s:Check(name, cond) abort
  if a:cond
    let s:passed += 1
    call writefile(['PASS ' .. a:name], '/tmp/acp_real_result.txt', 'a')
  else
    let s:failed += 1
    call writefile(['FAIL ' .. a:name], '/tmp/acp_real_result.txt', 'a')
  endif
endfunction

call writefile([], '/tmp/acp_real_result.txt')

let s:script_dir = fnamemodify(expand('<sfile>:p'), ':h')
execute 'source' s:script_dir . '/acp.vim'

" 选真实 agent
let g:acp_agent_cmd = ['claude-agent-acp']

AcpStart

" 等握手+session（node 启动慢，给 60s）
let s:chat = ''
let s:deadline = localtime() + 60
while localtime() < s:deadline
  sleep 200m
  let s:chat = join(getbufline(bufnr('acp-chat'), 1, '$'), "\n")
  if s:chat =~# 'session 建立成功'
    break
  endif
endwhile
call s:Check('handshake_session_new', s:chat =~# 'session 建立成功')

" 单轮文本问答（选最无害的问题，避免工具调用）
AcpSend reply with exactly the word: pong

" 等 end_turn（真实模型响应，给 120s）
let s:deadline = localtime() + 120
while localtime() < s:deadline
  sleep 300m
  let s:chat = join(getbufline(bufnr('acp-chat'), 1, '$'), "\n")
  if s:chat =~# 'stopReason=end_turn'
    break
  endif
endwhile

call s:Check('agent_replied_pong', s:chat =~# '\[AI\].*pong')
call s:Check('turn_end', s:chat =~# 'stopReason=end_turn')

call writefile(getbufline(bufnr('acp-chat'), 1, '$'), '/tmp/acp_real_chat.txt')

AcpStop

echom s:passed .. ' passed, ' .. s:failed .. ' failed'
if s:failed > 0
  cquit 1
endif
qa!
