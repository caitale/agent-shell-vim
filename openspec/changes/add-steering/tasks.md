# Tasks: add-steering

## 1. session 层

- [ ] 1.1 session.vim：`steer_mode` **四态**（unknown/native/queued/none）+ `id_steer` 语义 id；initialize 响应 `_meta.steering.supported` 直接标 native（W4 免首探）；`SteerText(text)` 分派（native 一律走 `_session/steering`——idle 也是，B3②；busy+queued→FirePrompt 直发+提示；busy+unknown→首探；queued/unknown 的 idle→SendPromptText）；-32601 降级（标 queued+自动重发本次内容）；连续 3 次非 -32601 错误→标 none+提示（W3）；queued 的 prompt 被拒→假阳性提示（W6）；Stop 重置 unknown（load/new 不重置）
- [ ] 1.2 presets.vim：透传 `steering` 声明（native/queued/none——none 提示不支持）；Resolve 返回值含该字段
- [ ] 1.3 outcome 呈现（injected/startedNewTurn 样式；未知 outcome 按原文）

## 2. render 与命令

- [ ] 2.1 render.vim：`SteerInput()` 导出（复用 SendInput 提取/防线/组包路径→SteerText）；SetupWindow 增 `<M-CR>` normal+insert 映射（经 # 全局名）
- [ ] 2.2 plugin：`:AgentSteer [text]`（无参=转发 SteerInput；带参直发）
- [ ] 2.3 提示样式 `[STEER]` 高亮组注册（SetupHighlight 补一行）

## 3. mock 夹具

- [ ] 3.1 mock_agent.py：`_session/steering` → 默认 `{outcome:'injected'}` + **self.pending 作废（B1 权限时序）** + 推"（收到转向）" + 挂起轮 end_turn；`MOCK_STEER=queued` → -32601 + **busy prompt 入 mock 侧队列（W-3：挂起轮完成后依序执行排队轮——服务端排队执行规格）**；`MOCK_STEER=queued_reject` → -32601 + busy prompt 回错误（假阳性路径）；`MOCK_STEER=err` → -32000（探测收敛）；`MOCK_STEER=new_turn` → `{outcome:'startedNewTurn'}`（N-4：startedNewTurn 独立断言）

## 4. 测试

- [ ] 4.1 回归 72 断言绿
- [ ] 4.2 新断言：busy 中 steer（native：injected 呈现 + **`[你·STEER]` 本地回显（B2）** + 轮次立即结束 + 权限行被转向覆盖）；空闲 steer native（startedNewTurn/injected 任一呈现——走 steering 通道，B3②）；转向不进队列（**经 `agent_shell#session#QueueDepth()` 断言**——N4：需导出，M4 已有）；降级（MOCK_STEER=queued 子进程：-32601→排队提示→内容重发→两轮依序）；假阳性（queued 的 session/prompt 报错→专门提示）；错误收敛（MOCK_STEER=err 连续 3 次→标 none 提示）；空输入 steer 拒绝；`[你·STEER]` 样式与 `[STEER]` outcome 行
- [ ] 4.3 `./t/run.sh` 全绿两连跑；真实冒烟：claude mid-turn steering（**数 1-200（W5 防 4s 完成）+第 4s 转向；主断言=输出含 STEERED-OK，「未数完」为软断言/人工核对**）、pi（busy 中 steer→排队提示→两轮完成）

## 5. 文档、verify 与归档

- [ ] 5.1 README：steering 章节（M-CR/降级语义/三桥矩阵简表/preset 声明示例/**双队列交错后果说明（W2）**/**`<M-CR>` 终端编码小节（W7：tmux xterm-keys 等）**）；命令表补 AgentSteer
- [ ] 5.2 openspec validate + verify（三维）→ 处理发现 → archive
- [ ] 5.3 提交 → push → CI 绿
