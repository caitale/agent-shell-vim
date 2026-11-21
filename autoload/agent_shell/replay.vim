vim9script
# replay.vim — traffic 回放引擎（add-traffic-replay design D1/D3）
#
# 把 g:agent_shell_debug 落盘的真实会话 JSONL 变成零 token 回归夹具：
# 加载 → 方向判别 → agent→client 方向逐条喂 session.Dispatch，
# 全程零进程、零 RPC。
#
# 方向判别（design D1，shape 规则 + 白名单）：
#   '^#'（行首字符，不 trim）→ 跳过（注释头；合法 JSON 行以 { 开头永不误杀）
#   method+id ∈ 白名单       → skipped_client（client 请求，跳过）
#   method 无 id              → 回放（agent 通知：session/update 等）
#   id+result|error           → 回放（agent 响应；id+1000 重映射——B2 语义 id 隔离）
#   method+id = request_permission → 回放（服务端请求）
#   其他（含未知 method+id）  → bad 计数
#
# 样本入库检查单与录制指南见 t/replay/README.md。

import autoload './session.vim'
import autoload './render.vim'

# 客户端方法白名单（协议面扩大时同步——与 mock 夹具同维护节奏；
# session/cancel 为预留：代码当前未发送过）
const CLIENT_METHODS = [
  'initialize', 'session/new', 'session/prompt', 'session/load',
  'session/list', 'session/set_mode', 'session/cancel', '_session/steering',
]

# 回放统计：replayed / skipped_client / bad / unknown_methods
export def Run(file: string): dict<any>
  var stats = {replayed: 0, skipped_client: 0, bad: 0, unknown_methods: []}
  if !filereadable(file)
    render.Log('RPLY', $'文件不存在：{file}')
    return stats
  endif
  var lines = readfile(file)
  for line in lines
    if line =~# '^#'
      continue
    endif
    if line =~# '^\s*$'
      continue
    endif
    try
      var msg = json_decode(line)
      if type(msg) != v:t_dict
        throw 'not a JSON object'
      endif
      if msg->has_key('method')
        if msg->has_key('id') && index(CLIENT_METHODS, msg['method']) >= 0
          stats['skipped_client'] += 1
        elseif msg->has_key('id') && msg['method'] ==# 'session/request_permission'
          # 服务端请求：agent→client 方向（Dispatch 已有 HandlePermission 分支）
          session.Dispatch(msg)
          stats['replayed'] += 1
        elseif !msg->has_key('id')
          # agent 通知
          session.Dispatch(msg)
          stats['replayed'] += 1
        else
          # 未知 method+id：防协议面扩大时静默漏放（design D1）
          stats['bad'] += 1
          if index(stats['unknown_methods'], msg['method']) < 0
            add(stats['unknown_methods'], msg['method'])
          endif
        endif
      elseif msg->has_key('id') && (msg->has_key('result') || msg->has_key('error'))
        # agent 响应：id 高段重映射（B2——与测试进程语义 id 隔离）
        msg['id'] = msg['id'] + 1000
        session.Dispatch(msg)
        stats['replayed'] += 1
      else
        stats['bad'] += 1
      endif
    catch
      # 整体 try/catch（W2）：decode 或分发任一异常计 bad，不中断
      stats['bad'] += 1
    endtry
  endfor
  return stats
enddef

# :AgentReplay 入口：回放 + 统计行呈现
export def RunAndReport(file: string): dict<any>
  var stats = Run(file)
  if !filereadable(file)
    return stats
  endif
  var unknown = ''
  if !empty(stats['unknown_methods'])
    unknown = $'（未知方法需同步白名单：{join(stats["unknown_methods"], ",")}）'
  endif
  render.Log('RPLY', $'回放完成：replayed={stats["replayed"]} skipped={stats["skipped_client"]} bad={stats["bad"]}{unknown}')
  return stats
enddef
