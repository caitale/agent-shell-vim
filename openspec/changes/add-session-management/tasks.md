# Tasks: add-session-management

## 1. sessions 模块与登记表

- [x] 1.1 新建 `autoload/agent_shell/sessions.vim`：registry LRU（cap 20，同 sessionId 去重更新）、`Register/Registry/RemoveEntry`；存储 `SaveRegistry/LoadRegistry`（默认 `~/.cache/agent-shell-vim/sessions.json`，`g:agent_shell_registry_path` 可覆盖；mkdir -p；损坏重置警告）
- [x] 1.2 session.vim：握手 new 成功与 load 成功路径调 `sessions.Register`；`session_info_update` 解析 title 存模块状态（供登记与 Current 展示）
- [x] 1.3 plugin 入口四命令：`:AgentSessionList` / `:AgentSessionLoad [n?]` / `:AgentSessionNew` / `:AgentSessionCurrent`（命令名与函数名解耦、call 形式——坑清单）

## 2. 列表与加载

- [x] 2.1 session.vim：`id_list/id_load` 语义 id 登记（最近 id 优先、陈旧响应丢弃）；`ListSessions()` 发送 session/list；`LoadSession(entry)` 发送 session/load（参数含条目原始 cwd + mcpServers:[]）
- [x] 2.2 nextCursor 翻页：响应含非空 cursor 时续拉合并（上限 5 页防御）
- [x] 2.3 sessions.vim：`list_entries` 状态 + render 渲染（`[SESS] n. title (MM-DD HH:MM, cwd尾段)` 行；空表提示"无历史会话"）；`:AgentSessionLoad <n>` 序号校验（无效→提示可选范围不发 RPC）
- [x] 2.4 load 响应处理：成功→sessionId 替换 + render「已恢复会话」+ Register 刷新；失败→错误呈现、当前会话不变；自动启动路径失败→RemoveEntry + 提示

## 3. 新建与查询

- [x] 3.1 `:AgentSessionNew`：复用握手 new（id 走自增，响应分支同 1.2 登记新条目）；聊天 buffer 标记「── 新会话 ──」分隔
- [x] 3.2 `:AgentSessionCurrent`：呈现 preset/sessionId/title

## 4. mock 夹具扩展

- [x] 4.1 mock_agent.py：`session/list` → 两条（`sess_mock_known` 可载 / `sess_mock_expired` 报错）+ nextCursor:null；`MOCK_SESS_MODE=empty` 空表、`=paged` 两页（W2 场景驱动）；`session/load` → known 成功（self.sid 同步 + 确认 chunk）、expired/其他 → -32602

## 5. 测试

- [x] 5.1 既有 35 断言回归绿（夹具变更零破坏）
- [x] 5.2 新断言：list 渲染（两条 `[SESS]` 行 + 序号）；序号无效（Load 99 提示不发）；load 成功（`agent_shell#session#SessionId()` 变为 sess_mock_known + 「已恢复会话」行 + mock 确认消息）
- [x] 5.3 新断言：load 失败保持现状（`:AgentSessionLoad 2`（expired 条目）→ error 行 + 原 sessionId 不变）；登记表持久化（g:agent_shell_registry_path 指 /tmp，Register→文件读回一致）；空登记表无参 load 提示不发；失效条目 RemoveEntry。（verify 勘误：「损坏文件重置」断言未写——实现存在 sessions.vim LoadRegistry catch 分支，测试留 M4 补）
- [x] 5.4 新断言：`:AgentSessionNew`（sessionId 变化 + 新会话标记）；`:AgentSessionCurrent`（含 sessionId）；busy 拒绝（轮次中 load → 提示不发）；agent 未启动时 list/带参 load 提示
- [x] 5.4b 新断言（MOCK_SESS_MODE 子进程场景）：empty 空表提示、paged 两页合并——单独 vim 进程跑（夹具按 env 切形态）
- [x] 5.5 `./t/run.sh` 全绿 49/49（两连跑稳定）；真实冒烟：后端 magpie 代理 502 挂起（环境问题非插件回归，wire dump 证实 prompt 已正确发出）——留待代理恢复后补跑，load 成功形状记档待办

## 6. 文档、verify 与归档

- [x] 6.1 README：会话管理章节（四命令/登记表说明/缓存路径）、命令表与配置表补全
- [x] 6.2 openspec validate + **verify（三维核对：任务证据/场景覆盖/设计遵从）** → 处理发现 → archive
- [x] 6.3 提交 → push → CI 绿（补救提交后执行）
