" test_steer_modes.vim — MOCK_STEER 子进程场景（queued/queued_reject/err/new_turn）
" 用法：MOCK_STEER=<mode> vim -Nu NONE -n -es -S t/test_steer_modes.vim -c 'qa!'
let s:passed = 0
let s:failed = 0
function! s:Check(name, cond) abort
  if a:cond
    let s:passed += 1
    call writefile(['PASS ' . a:name], '/tmp/as_steer_mode_result.txt', 'a')
  else
    let s:failed += 1
    call writefile(['FAIL ' . a:name], '/tmp/as_steer_mode_result.txt', 'a')
  endif
endfunction
call writefile([], '/tmp/as_steer_mode_result.txt')
let s:mode = exists('$MOCK_STEER') ? $MOCK_STEER : ''
let s:root = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'set rtp^=' .. s:root
execute 'source ' .. s:root . '/plugin/agent-shell.vim'
let g:agent_shell_registry_path = '/tmp/as_steer_reg.json'
call agent_shell#sessions#ResetForTest()

AgentStart
let s:d = localtime() + 5
while localtime() < s:d
  sleep 50m
  if join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# 'session 建立成功'
    sleep 200m | break
  endif
endwhile

if s:mode ==# 'preset_none'
  " preset 显式声明 none（scenario R2-6/R2-2 同路径）
  let g:agent_shell_agents = {'mockn': {'cmd': ['python3', s:root . '/t/mock_agent.py'], 'desc': 'n', 'steering': 'none'}}
  AgentStop
  execute 'AgentStart mockn'
  " 等待锚点：本轮特有 sid（文件头默认 AgentStart 的'建立成功'残留会假 break）
  let s:sid0 = agent_shell#session#SessionId()
  let s:d = localtime() + 5
  while localtime() < s:d
    sleep 100m
    if agent_shell#session#SessionId() !=# '' && agent_shell#session#SessionId() !=# s:sid0
      break
    endif
  endwhile
  sleep 300m
  call agent_shell#session#SteerText('blocked')
  let s:d = localtime() + 3
  while localtime() < s:d
    sleep 100m
    if join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# '不支持转向'
      break
    endif
  endwhile
  call s:Check('steer_preset_none_blocked',
        \ join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# '不支持转向（preset 声明 none）')

elseif s:mode ==# 'new_turn'
  " startedNewTurn：idle steer → 桥自起轮 → busy 对齐 + 新轮消息
  call agent_shell#session#SteerText('start-new')
  let s:d = localtime() + 5
  while localtime() < s:d
    sleep 100m
    if join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# '已开启新轮次'
      break
    endif
  endwhile
  sleep 300m
  let s:chat = join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n")
  call s:Check('steer_new_turn_busy_aligned',
        \ s:chat =~# '已开启新轮次' && agent_shell#session#IsBusy())
  " 等新轮权限挂起后收尾
  let s:d = localtime() + 5
  while localtime() < s:d
    sleep 100m
    if join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# 'Agent 请求权限'
      AgentPermReject
      sleep 300m | break
    endif
  endwhile

elseif s:mode ==# 'err'
  " 探测收敛：3 次 -32000 → none + 提示
  for i in range(3)
    call agent_shell#session#SteerText('probe-fail-' . i)
    sleep 400m
  endfor
  let s:chat = join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n")
  call s:Check('steer_probe_converge_none',
        \ s:chat =~# '连续探测失败——标记为不支持')
  " C-3：busy 语境的 steer 错误不误清 busy（挂起权限轮仍在）
  AgentSend busy-err-probe
  let s:d = localtime() + 5
  while localtime() < s:d
    sleep 100m
    if join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# 'Agent 请求权限'
      break
    endif
  endwhile
  call agent_shell#session#SteerText('busy-err-steer')
  sleep 600m
  call s:Check('steer_busy_err_keeps_busy', agent_shell#session#IsBusy())
  let s:d = localtime() + 5
  while localtime() < s:d
    sleep 100m
    if join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# 'Agent 请求权限'
      AgentPermReject
      sleep 300m
      break
    endif
  endwhile
  " none 后再 steer → 提示不发
  call agent_shell#session#SteerText('after-none')
  sleep 200m
  call s:Check('steer_none_blocked',
        \ join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# '不支持转向（preset 声明 none）')

elseif s:mode ==# 'queued'
  " 降级：首探 -32601 → queued + 重发排队 + 两轮依序
  AgentSend first-turn
  let s:d = localtime() + 5
  while localtime() < s:d
    sleep 100m
    if join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# 'Agent 请求权限'
      break
    endif
  endwhile
  call agent_shell#session#SteerText('steer-queued-msg')
  let s:d = localtime() + 6
  while localtime() < s:d
    sleep 100m
    if join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# '降级为服务端排队'
      break
    endif
  endwhile
  let s:chat = join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n")
  call s:Check('steer_degrade_queued',
        \ s:chat =~# '降级为服务端排队语义' && s:chat =~# '已交由 agent 服务端排队')
  call s:Check('steer_queued_no_local_echo',
        \ s:chat !~# '\[你·STEER\] steer-queued-msg')
  " 答第一轮权限 → 第一轮完成 → 排队轮依序执行
  AgentPermAllow
  let s:d = localtime() + 10
  while localtime() < s:d
    sleep 150m
    if join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# 'steer-queued-msg'
      break
    endif
  endwhile
  let s:chat = join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n")
  call s:Check('steer_two_turns_ordered',
        \ s:chat =~# 'Queued message' && s:chat =~# '收到（排队轮）：「steer-queued-msg」')
  " 收尾排队轮权限
  let s:d = localtime() + 5
  while localtime() < s:d
    sleep 100m
    if join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# 'Agent 请求权限'
      AgentPermAllow
      sleep 300m | break
    endif
  endwhile

elseif s:mode ==# 'queued_reject'
  " 假阳性：降级后 busy prompt 被拒 → 错误呈现
  AgentSend first-turn
  let s:d = localtime() + 5
  while localtime() < s:d
    sleep 100m
    if join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# 'Agent 请求权限'
      break
    endif
  endwhile
  call agent_shell#session#SteerText('steer-rejected')
  let s:d = localtime() + 6
  while localtime() < s:d
    sleep 100m
    if join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n") =~# '请求失败'
      break
    endif
  endwhile
  let s:chat = join(getbufline(bufnr('agent-shell-chat'), 1, '$'), "\n")
  call s:Check('steer_false_positive_err',
        \ s:chat =~# '请求失败（id=' && s:chat =~# '可能不支持排队')
endif

call writefile(getbufline(bufnr('agent-shell-chat'), 1, '$'), '/tmp/as_steer_chat.txt')
AgentStop
qa!
