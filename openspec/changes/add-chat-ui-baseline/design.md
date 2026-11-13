# Design: add-chat-ui-baseline

## Context

M0 已交付四模块骨架；本设计只回答聊天 UI 基线如何落在 render.vim（及其对 session/plugin 的最小侵入）。约束与 M0 相同：纯 Vim 内建能力、headless 可测、vim9script 踩坑清单全部适用（尤其 funcref/lambda 类型规则——timer 回调同样会踩）。

## Goals / Non-Goals

**Goals**：输入区常驻且流式安全；busy 指示无残留；折叠块自包含；布局可切换；全部在 headless 断言覆盖。

**Non-Goals**：@文件 / /斜杠补全（M4）；markdown 渲染（M4/M5 评估）；popup 悬浮预览（M5）；多窗口/多会话（M3）；输入区语法高亮。

## Decisions

### D1：输入区实现——尾部锚点 + appendbufline 到分隔线前

聊天 buffer 结构：`[历史区][分隔线 "── input ──"][输入区（≥1行）]`。

- 分隔线行号存模块级 `input_lnum`；所有历史追加用 `appendbufline(buf, input_lnum - 1, line)` 后 `input_lnum += 1`
- 发送：读取 `[input_lnum+1, $]` 非空行 join("\n") → session.SendPromptText → 清空输入区（保留一个空行）
- 历史区锁定：`setbufvar(buf, '&modifiable', 0)` 全 buffer 锁 + 输入区编辑通过 buffer-local 映射 `i`/`o`/`a` 等重定向到输入区行——**决策：M1 不做整 buffer 锁**，改为「历史区行以 `[` 开头 + 发送侧已有防线」+ `nomodifiable` 仅在无输入焦点场景。理由：headless 下锁/解锁时序复杂度高，且用户误改历史只影响显示不影响协议层。降级接受：文档标注"历史区请勿手改"
- 流式期间用户在输入区：appendbufline 插历史不影响输入区行内容，光标在输入区时无需特殊处理（行内容不变）

### D2：busy 指示——statusline 局部选项，不用 buffer 行

**决策：busy 指示画在窗口局部 `statusline`（`w:agent_shell_busy` + `&l:statusline`），不往 buffer 里插行。** 理由：spec 要求"停止后 buffer 无残留行"——插行方案必须精确删除，异常路径（error/中断）易漏；statusline 方案停止时恢复局部 statusline 即可，天然零残留。headless 测试断言改为检查 `session.IsBusy()` 状态 + （有窗口时）`w:agent_shell_busy`。旋转字符帧用 `timer_start(120ms, repeat)` 驱动，帧序 `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`；轮次期间 `%{agent_shell#render#BusyFrame()}`。

- 备选否决：buffer 顶部置顶行（残留风险）；popup（M5 再用于预览）。
- timer 回调是 funcref：**严格走 script-local def 转发**（M0 实证的 lambda/import 类型坑）。
- **statusline 模板串用单引号普通字符串**拼 `%{...}`（`$'...'` 插值遇字面 `{` 报 E1279）；**常驻局部 statusline** `%{agent_shell#render#StatusLine()}`（评审 N5：内部拼 busy 段，免保存/恢复原值状态机，窗口重开自愈）。
- **timer 生命周期（评审 W1/W2）**：`BusyFrame()` 变更不会触发重绘——每 tick 回调内更新帧计数后对聊天窗口 `redrawstatus`；tick 自检 `session.IsBusy()` 为假或窗口已关则 `timer_stop` 自灭，无常驻重绘。`BusyFrame/StatusLine` 必须 `export def`（autoload 模块的 export 会注册 `#` 全局名，statusline `%{}` 才能引用——script-local def 无全局名）。

### D3：折叠块——marker 局部于 buffer，工具块模板

tool_call 渲染模板：

```
▸ TOOL grep: completed {{{1
  <content 若干行>
}}}
```

- **foldmethod/foldmarker/foldlevel 均为 window-local**（评审 B3 纠正）：Open() 成功开窗后 `setwinvar(winid, '&foldmethod', 'marker')` 等设置；无窗口（headless）不设置——与降级语义和"断言文本结构"自洽
- 摘要行含 marker（`{{{1`），折叠态由 Vim 原生 fold 呈现单行——**无需自管折叠状态**
- 降级：`:AgentOpen` 时若用户全局 `foldmethod` 非 marker 且 `g:agent_shell_fold` 未显式开启，则 buffer 局部仍设 marker（局部覆盖全局是 Vim 语义，天然"可用"）；真正的不可用场景（终端不支持折叠渲染，极罕见）由 spec 的降级场景覆盖：渲染函数本身不依赖 fold 存在，marker 文本无 fold 时就是普通文本
- 测试断言：文本结构（marker 行存在）而非 fold 视觉状态——headless 下 fold 视图不可靠

### D4：高亮——syntax region 匹配前缀

- `:AgentOpen` 时对聊天 buffer 执行 `syntax match AgentShellAI /^\[AI\]/` 等一批 + 默认 `hi def link`（尊重用户 colorscheme：全部 `hi def`，用户已定义则不覆盖）
- `g:agent_shell_highlight = 0` 关闭（不注册 syntax）
- headless 断言：`hlexists('AgentShellAI')`（syntax 注册不依赖窗口显示）

### D5：布局——`:AgentOpen [right|bottom]`，右宽度/底高度可配

- `g:agent_shell_layout = 'bottom'`（默认）| `'right'`；命令参数覆盖配置
- right：`execute 'vertical botright ' .. g:agent_shell_right_width .. 'split'`（默认 46）；bottom：`execute 'botright ' .. g:agent_shell_bottom_height .. 'split'`（默认 12）——`w:width` 只是普通变量不控制窗口（评审 B4）
- headless（-es）无窗口：Open 保持 M0 行为（只保证 buffer 存在），布局分支以 `bufwinnr(b) != -1` 判定窗口存在才走（headless 下 split 静默失败、bufwinnr 恒 -1，天然不触发）——此判定同时是 busy timer 的启动条件（评审 B5：$TERM/恒真判定均不可用，bufwinnr 是唯一正确判定）

### D6：session 的 busy 钩子——状态查询函数而非事件

session.vim 增加模块状态 `busy`：SendPromptText 发出后置 true；HandleResponse 收到 stopReason/error、PermAnswer 拒绝路径置 false。对外 `session.IsBusy()`。render 的 statusline 表达式轮询该状态（statusline `%{}` 每次刷新求值，无需事件订阅）——零回调、零新依赖边。

## Risks / Trade-offs

- [statusline 方案在无窗口 headless 下不可见] → spec 场景按"状态可见性=IsBusy()+窗口表达式"双层定义；测试断言 IsBusy()
- [历史区不锁定的误改风险] → 文档标注 + 行前缀防线（发送侧拒 `[` 开头）；M2 若引入审查交互再评估升级锁定
- [appendbufline 频繁插入的性能] → 单轮消息量级 <1000 行，Vim buffer 操作足够；不做节流
- [输入区行被用户全部删光] → 发送/渲染前 EnsureInputArea() 兜底重建分隔线与空行
- [undo 历史破坏锚点（appendbufline 进 undo 树）/手改致 input_lnum 失步] →（评审 W3）buffer 创建时 `setbufvar('&undolevels', -1)` 切断 undo 破坏源；Log/Update 入口按分隔线文本 `── input ──` 重锚（行数小，开销可忽略），EnsureInputArea 仅为最后防线
- [headless 下 buffer-local 映射绑错对象] →（评审 W7）发送路径收敛为 `export def SendInput()`，映射与测试共用同一入口
- [timer 在 -es 下行为] → busy 帧字符更新用 `:setbufvar`+statusline 求值，timer 只在交互模式启动；headless 下 IsBusy() 状态照常变化（帧动画不跑）

## Migration Plan

纯增量渲染层改造 + 两条既有断言适配（M0 测试的行锚点逻辑遇分隔线需 +2 偏移）。回滚：revert 本次 commit 即回 M0 行为，无数据迁移。

## Open Questions

无（输入区锁定强度已在 D1 决策为文档化降级；若评审有异议可当场调整）。
