# Tasks: add-chat-ui-baseline

## 1. 布局与 buffer 结构

- [x] 1.1 render.vim：`Open(layout?)` 支持 right/bottom（botright/vertical botright split；右宽 `g:agent_shell_right_width`=46、底高 `g:agent_shell_bottom_height`=12、默认 `g:agent_shell_layout`='bottom'）；已开窗口时聚焦不重建；headless 无窗口时保持 buffer 就绪
- [x] 1.2 plugin/agent-shell.vim：`:AgentOpen [right|bottom]` 参数解析（`-nargs=?`）传入 render.Open；新配置项写入头部注释
- [x] 1.3 render.vim：buffer 结构初始化——首次创建时写入分隔线 `── input ──` 与一行空输入区，`input_lnum` 锚定；`EnsureInputArea()` 兜底（分隔线/输入区被删时重建）

## 2. 常驻输入区与发送语义

- [x] 2.1 Log/Update 的历史追加改为插入分隔线之前（appendbufline 到 `input_lnum-1`，锚点自增）；流式追加后输入区行内容与光标不受影响
- [x] 2.2 `<CR>` 新语义（`export def SendInput()` 统一入口，映射与测试共用）：读输入区全部非空行**保序** join（仅去首尾空白行，中间空行保留）；空输入区整条拒绝并提示（含 `[` 开头行，防线语义=M0 的整条拒绝）；发送后清空输入区、光标回到输入区首行
- [x] 2.3 移除 `SendCurrentLine`（BREAKING，proposal 已声明）；`y/n` 权限按键保留；**新增 `inoremap <buffer> <CR>` 转发 SendInput**（多行输入在 insert 模式），README 说明换行方式（粘贴多行 / `<C-V><CR>`）——评审 W5
- [x] 2.4 历史区防误改：README/help 标注"历史区请勿手改，行以 [ 开头受发送防线保护"（design D1 降级决策）

## 3. busy 指示

- [x] 3.1 session.vim：模块状态 busy + `IsBusy()`；SendPromptText 置 true；HandleResponse 的 stopReason/error 分支、PermAnswer 拒绝路径置 false；**Stop() 与 SendRaw 失败分支亦置 false**（评审 W6）
- [x] 3.2 render.vim：`BusyFrame()/StatusLine()` 均 **export def**（statusline `%{}` 需全局名，autoload export 自动注册）；常驻局部 statusline `%{agent_shell#render#StatusLine()}`（内部拼 busy 段，免恢复状态机）；帧序 ⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏；timer 启动/自灭条件= `bufwinnr(chatbuf) != -1`（评审 B5：$TERM 判定无效）；每 tick `redrawstatus`，tick 自检 IsBusy()=false 即 timer_stop（W1/W2）
- [x] 3.3 处理 Vim9 timer 回调类型（script-local def 转发，不踩 E1013）

## 4. 折叠与高亮

- [x] 4.1 render.vim：tool_call 块模板（`▸ TOOL title: status {{{1` + content 缩进行 + `}}}`）；available_commands_update 保持单行不折叠；plan/usage 不折叠
- [x] 4.2 Open() 开窗后 `setwinvar` 设 foldmethod=marker + **自定义 foldmarker `«as»,«/as»`**（W4：防误折叠 vim 内容）+ foldlevel=1；headless 无窗口不设（B3：三者均 window-local）；渲染不依赖 fold 存在（marker 文本在无 fold 环境即普通文本，天然降级）
- [x] 4.3 高亮：`:AgentOpen` 时注册 `AgentShell{AI,You,TOOL,PLAN,PERM,ERR,USE,CMD}` syntax match + `hi def link`（尊重用户配色）；`g:agent_shell_highlight=0` 跳过

## 5. 测试

- [x] 5.1 适配既有 14 断言：行锚点偏移（分隔线+输入区结构行）；**tool_call_rendered 断言适配新模板**（`▸ TOOL` + marker，W9）；`[你]` 回显断言不受输入区影响
- [x] 5.2 新断言：输入区结构（分隔线存在、input_lnum 锚定）；多行发送语义经 **`render#SendInput()` 导出入口**直接调用（W7：headless 下 buffer 映射不可测）；EnsureInputArea 重建
- [x] 5.3 新断言：busy 生命周期（SendPromptText 后 IsBusy()=true；end_turn/refusal/error 后 false）
- [x] 5.4 新断言：折叠块文本结构（tool_call 渲染含 `«as»` 与 `«/as»` marker 行）；高亮注册（hlexists 仅覆盖注册流程执行——W8 注明；有窗口时补 synID 断言）与 `g:agent_shell_highlight=0` 跳过
- [x] 5.5 新断言：布局函数——headless 下 Open('right')/Open('bottom') 不报错且 buffer 就绪（窗口分支经 bufwinnr 判定自然跳过，N3）；非法布局参数报错回默认（N4）
- [x] 5.6 真实 agent 冒烟重跑（claude，流式期间验证输入区不受打扰——手动检查项写入 smoke 输出末尾提示）
- [x] 5.7 `./t/run.sh` 全绿

## 6. 文档与归档

- [x] 6.1 README：新配置项表（layout/right_width/bottom_height/highlight）、`:AgentOpen [right|bottom]` 用法、输入区多行发送说明、历史区勿改提示
- [x] 6.2 openspec validate + 对照 spec 场景核对（自动断言 + 手动清单：流式期间输入区体验、busy 动画视觉与自灭、折叠开合交互、右侧布局宽度生效、重复打开聚焦、高亮视觉——W10，验收时逐项勾）
- [x] 6.3 提交 → archive
