vim9script
# presets.vim — agent preset 注册表：内置三 preset + 用户自定义合并
#
# preset 结构：{cmd: list<string>, desc: string}
# 设计（design D4）：不碰凭证——凭证与路由全在 agent 侧（CLI env / 桥），
# 客户端只负责 spawn。pi 的 `env -u NODE_OPTIONS` 是本机 shim 特例，
# 不进默认 preset，doc 中作为自定义示例。

# 插件根：本文件位于 <root>/autoload/agent_shell/，向上两级
const ROOT = fnamemodify(expand('<sfile>:p'), ':h:h:h')

# 内置 preset 表
def Builtin(): dict<any>
  return {
    mock: {
      cmd: ['python3', ROOT .. '/t/mock_agent.py'],
      desc: 'mock agent（测试基准，仅需 python3）',
    },
    claude: {
      cmd: ['claude-agent-acp'],
      desc: 'Claude（claude-agent-acp 适配器；凭证由 claude CLI 自行管理）',
    },
    pi: {
      cmd: ['pi-acp'],
      desc: 'pi coding agent（@geohar/pi-acp 桥；凭证由 pi 自行管理）',
    },
  }
enddef

# 全部 preset：内置 + 用户表浅合并（用户同名覆盖内置）
export def All(): dict<any>
  var table = Builtin()
  if exists('g:agent_shell_agents') && type(g:agent_shell_agents) == v:t_dict
    for [name, item] in items(g:agent_shell_agents)
      if type(item) == v:t_dict && has_key(item, 'cmd') && type(item['cmd']) == v:t_list
        table[name] = item
      endif
    endfor
  endif
  return table
enddef

# 按名解析：不存在时返回空 dict（调用方负责报错列出可用名）
export def Resolve(name: string): dict<any>
  var table = All()
  if name ==# ''
    # 默认 preset：mock（spec：agent-presets「默认 preset」场景）
    return table->get('mock', {})
  endif
  return table->get(name, {})
enddef

# 可用 preset 名列表（错误提示与命令补全用）
export def Names(): list<string>
  return All()->keys()->sort()
enddef
