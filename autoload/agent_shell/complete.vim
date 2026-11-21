vim9script
# complete.vim — 输入区补全数据源（@文件 / /斜杠命令）
#
# 设计（add-production-features design D1）：
#   FilesFor：前缀驱动（无前缀只给一层目录，有前缀才递归 glob——N2 防卡顿）
#   CommandsFor：数据源 session.AvailableCommands()（available_commands_update 缓存）
#   菜单交互（completefunc/Tab）headless 不可测——断言只测本模块返回列表
# 依赖：complete → session（只读查询）；被 render 的 completefunc 引用（# 全局名）

import autoload './session.vim'

const MAX_ITEMS = 50

# @ 文件补全：prefix 为 @ 后的路径片段（可为空）
# 返回 [{word: 相对路径, menu: 目录, kind: 'f'/'d'}]
export def FilesFor(prefix: string): list<dict<any>>
  var out: list<dict<any>> = []
  var cwd = getcwd()
  if prefix ==# ''
    # 无前缀：一层目录概览（不递归——N2）
    for e in split(globpath(cwd, '*', 1, 1), "\n")
      var rel = fnamemodify(e, ':.')
      if rel !~ '^\.'  # 隐藏项跳过
        add(out, {
          word: rel,
          menu: isdirectory(e) ? '[dir]' : fnamemodify(e, ':e'),
          kind: isdirectory(e) ? 'd' : 'f',
        })
      endif
      if len(out) >= MAX_ITEMS
        break
      endif
    endfor
  else
    # 有前缀：递归 glob（前缀目录内）
    var dir = fnamemodify(prefix, ':h')
    var pat = dir ==# '.' || dir ==# prefix ? prefix . '**' : dir . '/**'
    for e in split(globpath(cwd, pat, 0, 1), "\n")
      var rel = fnamemodify(e, ':.')
      if rel =~ '^\.'
        continue
      endif
      add(out, {
        word: rel,
        menu: isdirectory(e) ? '[dir]' : fnamemodify(e, ':e'),
        kind: isdirectory(e) ? 'd' : 'f',
      })
      if len(out) >= MAX_ITEMS
        break
      endif
    endfor
  endif
  return out
enddef

# / 斜杠命令补全：prefix 为 / 后的命令名片段（可为空）
export def CommandsFor(prefix: string): list<dict<any>>
  var out: list<dict<any>> = []
  for c in session.AvailableCommands()
    var name = c->get('name', '')
    if name ==# ''
      continue
    endif
    if prefix ==# '' || name =~? '^' .. escape(prefix, '.*[]^$')
      add(out, {
        word: name,
        menu: c->get('description', '')[:40],
        kind: 'c',
      })
    endif
    if len(out) >= MAX_ITEMS
      break
    endif
  endfor
  return out
enddef

# completefunc 入口（buffer-local 'completefunc' 引用——# 全局名）
# findstart：定位当前补全词起点；base 前缀在 1: 里给菜单
export def Input(findstart: number, base: string): any
  var line = getline('.')
  var col = col('.') - 1
  if findstart == 1
    # 光标前找 @ 或行首 / 的补全词起点
    var before = strpart(line, 0, col)
    var at = match(before, '[^ \t]*@$')  # @ 尾随词
    if at >= 0
      return at + 1  # 跳过 @ 本身？不——保留 @ 在词外，补全词从 @ 后开始
    endif
    if line =~# '^/'
      return 1  # 行首 / 后
    endif
    return -3  # 无补全语境：丢弃（保持输入不动）
  else
    # base 为当前补全词前缀
    var before = strpart(line, 0, col('.'))  # 不用——base 已给
    var items: list<dict<any>> = []
    # 判定语境：行内 @ 尾随 → 文件；行首 / → 命令
    var cur = strpart(getline('.'), 0, col('.') - 1)
    if cur =~# '@[^ \t]*$'
      items = FilesFor(base)
    elseif getline('.') =~# '^/'
      items = CommandsFor(base)
    endif
    # complete() 需 [word, menu, kind, info] 列表形态
    return items->mapnew((_: number, e: dict<any>) => [e['word'], e['menu'], e['kind'], ''])
  endif
enddef

# Tab 入口（render 的 inoremap 转发——# 全局名）
# 判定语境：行内 @尾随词 → 文件补全；行首 / → 命令补全；否则不动光标（默认 Tab 行为牺牲，逃生口 g:agent_shell_no_tab_map）
export def Tab()
  var line = getline('.')
  var col = col('.')
  var before = strpart(line, 0, col)
  var items: list<dict<any>> = []
  var base = ''
  if before =~# '@[^ \t]*$'
    base = matchstr(before, '@\\zs[^ \\t]*$')
    items = FilesFor(base)
  elseif line =~# '^/'
    base = matchstr(line, '^/\\zs.*$')
    items = CommandsFor(base)
  endif
  if empty(items)
    return
  endif
  # 弹出菜单（交互模式生效；headless 无害）
  var words = items->mapnew((_: number, e: dict<any>) => {'word': e['word'], 'menu': e['menu'], 'kind': e['kind']})
  call complete(col - len(base), words)
enddef
