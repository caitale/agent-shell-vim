vim9script
# protocol.vim — job 管理 + JSON-RPC 按行分帧 + 请求 id 计数 + stderr 策略 + 调试落盘
#
# 状态归属（design D1）：job 句柄归本模块；会话语义状态归 session.vim。
# 本模块不做任何 JSON 解析——只管字节行进出与进程生命周期。

var job: job = null_job
var next_id = 1        # 请求 id 计数（语义分段由 session 决定，这里只发号）

# session 在 Start 前注册行回调（解耦：protocol 不 import session，避免双向依赖）
# 注意：funcref 变量名必须大写开头（E704）
def NoopLine(_: string)
enddef
var On_line_cb: func(string): void = function('NoopLine')
# verbose 模式的 stderr 通道（protocol→render 唯一例外边，design D2）
def NoopErr(_: string)
enddef
var On_stderr_cb: func(string): void = function('NoopErr')

export def Running(): bool
  return job != null_job
enddef

export def NextId(): number
  var id = next_id
  next_id += 1
  return id
enddef

# 回调注册（session 在 Start 前调用）。
# 设计原因：vim9script 下跨模块 funcref 传递只能用 lambda（script-local def
# 无全局名，function('name') 不可用）。参数类型用 func(any) 放宽——
# 严格 func(string) 会因 lambda 返回值推断（any/number）触发 E1013（实证）。
export def SetCallbacks(OnLine: func(string): void, OnStderr: func(string): void)
  On_line_cb = OnLine
  On_stderr_cb = OnStderr
enddef

# 启动 agent 子进程。cmd 为完整命令行 list。
export def Start(cmd: list<string>): bool
  if job != null_job
    return false
  endif
  job = job_start(cmd, {
    out_mode: 'nl',
    err_mode: 'nl',
    out_cb: (ch: channel, msg: string) => OnLineRaw(msg),
    err_cb: (ch: channel, msg: string) => OnStderrRaw(msg),
  })
  return job != null_job
enddef

export def Stop()
  if job != null_job
    job_stop(job)
    job = null_job
  endif
enddef

# 发送一条 JSON-RPC 消息（dict 编码为单行 JSON + 换行）
export def Send(msg: dict<any>): bool
  if job == null_job
    return false
  endif
  ch_sendraw(job, json_encode(msg) .. "\n")
  return true
enddef

# ---------- 内部 ----------

def OnLineRaw(line: string)
  if line =~ '^\s*$'
    return
  endif
  DebugDump(line)
  On_line_cb(line)
enddef

def OnStderrRaw(line: string)
  if line =~ '^\s*$'
    return
  endif
  # stderr 默认静默降噪（真实适配器向 stderr 输出大量诊断日志）；
  # verbose 开启时经注册的回调透传到渲染层
  if exists('g:agent_shell_verbose') && g:agent_shell_verbose
    On_stderr_cb(line)
  endif
enddef

# 调试落盘：g:agent_shell_debug 非空时追加写原始行（双向流量均落盘：
# 发送侧由 session 在组包后调 DumpOutgoing）
def DebugDump(line: string)
  if exists('g:agent_shell_debug') && type(g:agent_shell_debug) == v:t_string && g:agent_shell_debug != ''
    try
      writefile([line], g:agent_shell_debug, 'a')
    catch
      # 落盘失败不干扰协议流（vim9script 注释是 #，" 会被当字符串开头）
    endtry
  endif
enddef

export def DumpOutgoing(line: string)
  DebugDump(line)
enddef
