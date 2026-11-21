# Tasks: add-production-features

## 1. 补全

- [x] 1.1 新建 `autoload/agent_shell/complete.vim`：`FilesFor(prefix)`（globpath 递归、50 项截断、相对化）、`CommandsFor(prefix)`（数据源 session.AvailableCommands()）
- [x] 1.2 session.vim：解析 available_commands_update 存 `avail_cmds` + export `AvailableCommands()`
- [x] 1.3 render.vim：输入区 SetupWindow 补 completefunc 注册 + `<Tab>` buffer-local inoremap（经全局名转发判定函数）；headless 断言只测数据源

## 2. 队列

- [x] 2.1 session.vim：`queue` FIFO + `g:agent_shell_queue_max`（默认 5）；SendPromptText busy 分支入队（溢出提示）；BusyClear 收口出队（150ms timer 延迟发送）；Stop 清队
- [x] 2.2 `:AgentQueueClear` 命令；[QUEUE] 提示行（入队/出队/清空）

## 3. 成本

- [x] 3.1 session.vim：usage_in/out/last_usage 累计（inputTokens/outputTokens 优先；used 仅展示）；load/new 成功重置
- [x] 3.2 `:AgentUsage` 呈现（累计+最近一轮）；render.StatusLine busy 段附简要（UsageBrief()）

## 4. 模式与配置

- [x] 4.1 session.vim：握手 new 响应**与 load 响应**（2026-11-20 实测：load 也返回完整 modes）解析 modes/configOptions 存模块态；`id_set_mode` 语义 id + set_mode 发送与响应呈现
- [x] 4.2 `:AgentMode [modeId?]`（无参列表带 `*` 当前；带参校验→RPC；无效提示）；`:AgentConfig`（configOptions 只读展示，模型标注"仅展示"）
- [x] 4.3 无 modes 数据桥降级提示

## 5. 图片

- [x] 5.1 session.vim：`pending_image` 槽；`:AgentImage <path>`（扩展名→mime、**getfsize<0 显式拒**、≤2MB、system('base64 < '..shellescape(path)) 失败 catch）；SendPromptText 组包 [text?, image] 发送后清槽 + [IMG] 提示
- [x] 5.2 render.SendInput（B4）：输入区空但 session 有挂起附件时放行发送（仅 image block）——空输入与 `[` 开头防线是两回事，后者不动

## 6. mock 夹具

- [x] 6.1 usage_update（每轮 completed 后推，双字段；`MOCK_USAGE_MODE=used_only` 开关测 B2 降级）；握手后 available_commands 两条；**session/new 响应带 modes{currentModeId:'auto',availableModes:[default/acceptEdits/plan/auto/bypassPermissions]} + configOptions[mode/model]（B3：对齐 /tmp/m4_probe 抓包形状——模式断言的数据源）**；set_mode（plan→{}；availableModes 内含 `reject_me` 项用于测 agent 拒绝路径——W3）；prompt 含 image block 回显

## 7. 测试

- [x] 7.1 回归 49 断言绿
- [x] 7.2 新断言：补全数据源（FilesFor 仓库文件命中/CommandsFor 命中 mock 命令）；队列（busy 入队计数提示→轮次结束自动发送→清空提示→超限拒绝→**换会话（new）队列清空提示**（B1））；usage（两轮累计/**Stop 重置**/换会话重置/used_only 降级总量口径）；模式（无参列表/plan 切换确认/bogus 拒绝/reject_me 的 agent 拒绝呈现/无 modes 降级提示）；图片（挂载→发送含 image 回显→清槽→**空输入仅图发送**（B4）；超限/格式/不存在路径拒绝）；**登记表损坏重置（B5：M3 余项——损坏 JSON→读→重置空+提示）**；呈现统一走 render.Log（N3，headless 可断言）
- [x] 7.3 `./t/run.sh` 全绿两连跑；真实冒烟待 magpie 恢复（挂起项沿 M3）

## 8. 文档、verify 与归档

- [x] 8.1 README：补全用法（Tab/@//、**Tab 覆盖声明与 no_tab_map 逃生口**）、队列说明与配置、成本/模式/图片命令；命令表配置表补全；删除 OnInputArea 遗留提及
- [x] 8.2 openspec validate + verify（三维）→ 处理发现 → archive
- [x] 8.3 提交 → push → CI 绿
