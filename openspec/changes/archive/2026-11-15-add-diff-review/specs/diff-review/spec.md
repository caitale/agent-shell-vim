## ADDED Requirements

### Requirement: 结构化 diff 捕获

edit 类工具调用的更新流中，插件从 tool_call_update 事件的 content 数组提取结构化 diff 条目（type=diff，含 path/oldText/newText），与 toolCallId 关联存入待审查队列。非 edit 类（无 diff content）不入队。同一 toolCallId 的多次更新（参数逐步补全、状态至 completed）合并为同一队列条目：diff 首见即定，后续状态更新仅变更条目状态；completed 时若启用自动审查且有窗口显示则自动打开审查视图。tool_call_update 事件类型若含状态字段则同步条目状态。

#### Scenario: edit 类捕获入队

- **WHEN** 收到 content 含 `{type:'diff', path, oldText, newText}` 的 tool_call_update
- **THEN** 该改动进入待审查队列，含文件路径与新旧文本

#### Scenario: 非 edit 类不入队

- **WHEN** 收到 bash/read 类（content 无 diff 条目）的工具调用更新
- **THEN** 待审查队列不变

#### Scenario: 同 toolCallId 更新合并

- **WHEN** 同一 toolCallId 先后收到参数补全更新与 completed 状态更新
- **THEN** 队列条目数不变，条目状态同步为 completed

#### Scenario: 自动审查弹出

- **WHEN** 配置开启自动审查，edit 条目收到 completed 更新且聊天 buffer 有窗口显示
- **THEN** 自动打开该条目的 vimdiff 审查视图

#### Scenario: 无窗口不自动弹

- **WHEN** 配置开启自动审查但聊天 buffer 无窗口显示（如 headless）
- **THEN** 不打开审查视图，条目正常入队等待手动审查

### Requirement: vimdiff 审查视图

对待审查项可打开 vimdiff 审查视图：新建 tabpage 中左侧为 oldText 生成的只读临时 buffer，右侧为该文件当前实际内容（打开前强制重读，避免 stale buffer 显示旧内容）。审查视图内提供接受与拒绝操作（全局命令与两侧窗口的 buffer-local 便捷映射）；操作完成后清理映射、关闭审查 tabpage、回到聊天窗口。

#### Scenario: 打开审查

- **WHEN** 在待审查的 TOOL 折叠块上按 `d`（或执行 `:AgentDiffReview`）
- **THEN** 新 tab 打开 vimdiff，左侧呈现旧文本，右侧呈现当前文件内容

#### Scenario: 接受并关闭

- **WHEN** 执行接受操作（`:AgentDiffAccept` 或审查视图映射 `]a`）
- **THEN** 文件内容保持不变，审查项标记为已接受，映射清理，审查 tab 关闭回到聊天窗口

#### Scenario: 拒绝并恢复

- **WHEN** 执行拒绝操作（`:AgentDiffReject` 或映射 `]r`）且文件当前内容与 newText 一致
- **THEN** 文件内容恢复为 oldText，审查项标记为已拒绝，映射清理，审查 tab 关闭

#### Scenario: 映射不残留

- **WHEN** 审查 tab 因接受/拒绝/手动关闭而结束
- **THEN** 审查便捷映射从两侧 buffer 上清除，用户文件 buffer 无残留映射

### Requirement: 拒绝写回一致性校验

执行拒绝时，若文件当前内容与 newText 不一致（agent 落盘失败或用户已修改），拒绝不写回 oldText，而是呈现警告并保持待审查状态；拒绝恢复成功后在聊天 buffer 提示"agent 不知此回滚，请在下轮告知"（改后审路线的上下文失真提示）。oldText 为空（新建文件场景）不做删除，呈现警告人工处理。

#### Scenario: 一致时恢复

- **WHEN** 拒绝时文件内容与 newText 一致
- **THEN** 文件恢复为 oldText，聊天 buffer 出现上下文失真提示

#### Scenario: 不一致时警告不写回

- **WHEN** 拒绝时文件内容与 newText 不一致
- **THEN** 文件不被修改，警告呈现，审查项保持待审查

#### Scenario: 空 oldText 不删除

- **WHEN** 拒绝时 oldText 为空（新建文件）
- **THEN** 文件不被删除，警告提示人工处理

### Requirement: 审查队列与状态标记

待审查项按到达顺序排列；接受/拒绝操作的目标为当前审查项（由 Review 设定），未设定时为首个待审查项，操作完成后清除该指向。聊天 buffer 中对应 TOOL 折叠块摘要行追加审查状态标记（入队时"待审查"，审查后 ✓/✗）。队列状态可查询（返回结构化列表：路径与状态）。

#### Scenario: 状态标记更新

- **WHEN** 某审查项被接受
- **THEN** 对应 TOOL 折叠块摘要行显示已接受标记

#### Scenario: 队列查询

- **WHEN** 执行队列查询
- **THEN** 返回全部条目的路径与状态列表（含已审查项）

#### Scenario: 无当前审查项时的默认目标

- **WHEN** 未打开过审查视图，直接执行 `:AgentDiffAccept`
- **THEN** 作用于首个待审查项
