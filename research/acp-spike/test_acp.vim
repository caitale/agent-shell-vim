" test_acp.vim — headless 集成测试
" 运行：vim -Nu NONE -n -es -S test_acp.vim -c 'qa!' （退出码 0 = 通过）
" 或交互观察：vim -Nu NONE acp.vim，然后 :AcpStart / :AcpSend ...

let s:passed = 0
let s:failed = 0

function! s:Check(name, cond) abort
  if a:cond
    let s:passed += 1
    call writefile(['PASS ' .. a:name], '/tmp/acp_test_result.txt', 'a')
  else
    let s:failed += 1
    call writefile(['FAIL ' .. a:name], '/tmp/acp_test_result.txt', 'a')
  endif
endfunction

call writefile([], '/tmp/acp_test_result.txt')
call delete('/tmp/acp_test_chat.txt')

" acp.vim 与本文件同目录：按脚本自身位置定位，避免绝对路径因项目迁移失效
let s:script_dir = fnamemodify(expand('<sfile>:p'), ':h')
execute 'source' s:script_dir . '/acp.vim'

" 启动
AcpStart

" 等待握手完成（session 建立会写日志到 buffer）
let s:deadline = localtime() + 5
while localtime() < s:deadline
  sleep 50m
  let s:chat = join(getbufline(bufnr('acp-chat'), 1, '$'), "\n")
  if s:chat =~# 'session 建立成功'
    break
  endif
endwhile

call s:Check('handshake_initialize_session', s:chat =~# 'session 建立成功')

" 发送 prompt，agent 会先发权限请求
AcpSend hello-acp

" 等待权限请求出现
let s:deadline = localtime() + 5
while localtime() < s:deadline
  sleep 50m
  let s:chat = join(getbufline(bufnr('acp-chat'), 1, '$'), "\n")
  if s:chat =~# 'PERM'
    break
  endif
endwhile
call s:Check('permission_request_arrived', s:chat =~# 'Agent 请求权限')

" 批准权限
AcpPermAllow

" 等待轮次结束
let s:deadline = localtime() + 5
while localtime() < s:deadline
  sleep 50m
  let s:chat = join(getbufline(bufnr('acp-chat'), 1, '$'), "\n")
  if s:chat =~# 'stopReason=end_turn'
    break
  endif
endwhile

call s:Check('user_message_echoed', s:chat =~# '\[你\] hello-acp')
call s:Check('streamed_agent_chunks', s:chat =~# '\[AI\] 收到：')
call s:Check('plan_update_rendered', s:chat =~# '\[PLAN\]')
call s:Check('tool_call_rendered', s:chat =~# '\[TOOL\] grep')
call s:Check('turn_completed_end_turn', s:chat =~# 'stopReason=end_turn')

" 保存聊天记录供检查
call writefile(getbufline(bufnr('acp-chat'), 1, '$'), '/tmp/acp_test_chat.txt')

AcpStop

echom s:passed .. ' passed, ' .. s:failed .. ' failed'
if s:failed > 0
  cquit 1
endif
qa!
