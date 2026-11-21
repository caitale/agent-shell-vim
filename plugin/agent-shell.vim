vim9script
# agent-shell.vim — 插件入口：命令定义与配置读取（无逻辑，逻辑在 autoload/agent_shell/）
#
# 命令：
#   :AgentStart [preset]   启动 agent（默认 mock）并握手
#   :AgentStop             停止 agent
#   :AgentOpen [right|bottom]  打开聊天窗口（默认 bottom；g:agent_shell_layout 可改默认）
#   :AgentSend <text>      发送一条 prompt（headless/脚本友好）
#   :AgentPermAllow        答复挂起的权限请求：允许
#   :AgentPermReject       答复挂起的权限请求：拒绝
#
# 配置（均可在 vimrc 设置）：
#   g:agent_shell_agents   自定义 agent 表 {name: {cmd: [...], desc: '...'}}，
#                          与内置同名时用户定义优先
#   g:agent_shell_verbose  非 0 时透传 agent stderr 到聊天 buffer（排障用）
#   g:agent_shell_debug    非空时为原始 JSONL 落盘路径（协议排障/回放）
#   g:agent_shell_layout   窗口布局默认值：'bottom'（默认）| 'right'
#   g:agent_shell_right_width  right 布局宽度（默认 46）
#   g:agent_shell_bottom_height bottom 布局高度（默认 12）
#   g:agent_shell_highlight    非 0 启用消息类型高亮（默认开启，0 关闭）
#   g:agent_shell_diff_auto    非 0 时 edit 完成自动打开 vimdiff 审查（默认 0）
#   g:agent_shell_diff_chain   非 0 时审查完自动跳下一待审查项（默认 0）
#   g:agent_shell_registry_path  会话登记表路径（默认 ~/.cache/agent-shell-vim/sessions.json）
#   g:agent_shell_queue_max     prompt 队列上限（默认 5）
#   g:agent_shell_no_tab_map    非 0 时不注册输入区 Tab 补全映射（completefunc 仍可用）

# 踩坑规避（spike 实证）：命令定义一律 command! X call Func()，
# 禁止 lambda 内联（静默 no-op）；命令名与函数名解耦（E117）。
# 注意：import autoload 的符号在命令执行时才解析首次加载；命令体引用
# 模块前必须已 import（此处三条 import 在命令定义前执行）。
import autoload '../autoload/agent_shell/session.vim'
import autoload '../autoload/agent_shell/render.vim'
import autoload '../autoload/agent_shell/presets.vim'
import autoload '../autoload/agent_shell/diff.vim'
import autoload '../autoload/agent_shell/sessions.vim'
import autoload '../autoload/agent_shell/complete.vim'

def DiffStatusEcho()
  for e in diff.Status()
    echom $'[{e.state}] {e.path} ({e.status})'
  endfor
enddef

command! -nargs=? -complete=custom,AgentShellPresetComp AgentStart call session.Start(<q-args>)
command! -nargs=? AgentDiffReview call diff.Review(<q-args> != '' ? str2nr(<q-args>) : -1)
command! AgentDiffAccept call diff.Accept()
command! AgentDiffReject call diff.Reject()
command! AgentDiffNext call diff.Next()
command! AgentDiffStatus call DiffStatusEcho()
command! AgentStop call session.Stop()
command! -nargs=? AgentOpen call render.Open(<q-args>)
command! -nargs=1 AgentSend call session.SendPromptText(<q-args>)
command! AgentPermAllow call session.PermAnswer('allow_once')
command! AgentPermReject call session.PermAnswer('reject_once')
command! AgentSessionList call sessions.ListSessions()
command! -nargs=? AgentSessionLoad call sessions.LoadDispatch(<q-args>)
command! AgentSessionNew call sessions.NewSession()
command! AgentSessionCurrent call sessions.ShowCurrent()
command! AgentQueueClear call session.QueueClear()
command! AgentUsage call session.ShowUsage()
command! -nargs=? AgentMode call sessions.ModeDispatch(<q-args>)
command! AgentConfig call session.ShowConfig()
command! -nargs=1 AgentImage call session.AttachImage(<q-args>)
command! -nargs=? AgentSteer call sessions.SteerDispatch(<q-args>)

# preset 名补全（转发到 presets 模块；解耦命名避免 E117）
def g:AgentShellPresetComp(arglead: string, _1: string, _2: number): string
  import autoload '../autoload/agent_shell/presets.vim'
  return presets.Names()->join("\n")
enddef
