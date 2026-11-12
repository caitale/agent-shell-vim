# Tasks: add-plugin-skeleton

## 1. 目录骨架与 preset 层

- [x] 1.1 创建 `plugin/agent-shell.vim`：定义六命令（AgentStart [preset] / AgentStop / AgentOpen / AgentSend / AgentPermAllow / AgentPermReject）与默认配置读取，入口不含逻辑
- [x] 1.2 创建 `autoload/agent_shell/presets.vim`：内置三 preset（mock/claude/pi，cmd + desc 结构，运行时定位 mock_agent.py）；与 `g:agent_shell_agents` 用户表浅合并（同名覆盖）；`Resolve(name)` 返回表项或报错列全部可用名
- [x] 1.3 mock 夹具迁移：`research/acp-spike/mock_agent.py` 复制到 `t/mock_agent.py`（t/ 为唯一真源；research 侧冻结不改）

## 2. 协议层

- [x] 2.1 创建 `autoload/agent_shell/protocol.vim`：`Start(cmd)` / `Stop()` / `Send(dict)` / `Running()`；job_start + out_mode:nl + err_mode:nl；行回调转发 session.OnLine；id 自增计数
- [x] 2.2 stderr 降噪：默认静默；`g:agent_shell_verbose` 开启时透传 render
- [x] 2.3 调试落盘：`g:agent_shell_debug`（路径）非空时每行原始 JSON 追加写文件

## 3. 会话层

- [x] 3.1 创建 `autoload/agent_shell/session.vim`：`Start(preset)` 驱动握手序列（initialize：无 fs/terminal 能力声明 → session/new：cwd + mcpServers:[]）；sessionId 提取与呈现
- [x] 3.2 OnLine 分发：按 id 关联响应（1→握手 / 2→会话 / ≥10→轮次 stopReason）；按 method 分发通知（session/update → render、session/request_permission → 权限挂起）
- [x] 3.3 prompt 组包（prompt block list）与 next_id 递增；`Send(text)`、`PermAnswer(optionId)`（无挂起时提示不发消息）
- [x] 3.4 wire format 判别按 `params.update.sessionUpdate`；未知 update 类型静默跳过（前向兼容）

## 4. 渲染层

- [x] 4.1 创建 `autoload/agent_shell/render.vim`：bufadd/bufload 无窗口聊天 buffer（buftype=nofile）；Log(kind, text)
- [x] 4.2 update 类型渲染，行为逐类型明确：user_message_chunk / agent_message_chunk / plan / tool_call / available_commands_update 正常渲染；agent_thought_chunk / usage_update 提示级渲染（单行摘要）；其余已知类型静默跳过
- [x] 4.3 `:AgentOpen` 打开窗口 + buffer-local 按键（CR 发送当前行、y/n 答复权限）；预留 M1 输入区挂载点（空函数 + 标记注释）
- [x] 4.4 stderr/诊断的渲染通道（配合 2.2）

## 5. 测试迁移与 CI

- [x] 5.1 编写 `t/test_protocol_session.vim`：**先 `set rtp^=<插件根>` 再 source plugin 入口**（D3 headless 加载路径），整链路测试；迁移 spike 主流程 7 断言（握手/权限到达/回显/流式/plan/tool_call/end_turn）
- [x] 5.2 迁移拒绝分支 2 断言（PermReject → stopReason=refusal）
- [x] 5.3 补最小断言：噪音行容错（mock 夹具输出脏行不中断）、preset 解析（默认 mock / 未知名报错列清单 / 用户自定义覆盖内置）
- [x] 5.4 编写 `t/run.sh`（设置 rtp + headless 跑法 + 结果文件 + 退出码）；本地跑绿
- [x] 5.5 新增 `.github/workflows/test.yml`：action-setup-vim 矩阵（9.1/9.2）→ `t/run.sh`
- [x] 5.6 真实 agent 冒烟脚本迁移到 `t/smoke_real.vim`（不进 CI，手动跑；claude/pi 两 preset 参数化）

## 6. 验收与归档

- [x] 6.1 对照 spec 三 capability 逐条核对（openspec validate + verify）。核对方式清单：acp-transport 的生命周期/分帧/降噪/落盘与 acp-session 的握手/轮次/判别/权限（自动：t/ 测试）；stderr 显式开启、session/new 被拒（手动：设置开关/断开 agent 观察）；agent-presets 全部场景（自动：preset 解析断言 + 手动：三 preset 冒烟 5.6）
- [x] 6.2 更新根 README（安装方式、命令表、三 preset 说明、自定义 agent 示例——含 pi 的 env -u NODE_OPTIONS 示例；research/acp-spike README 标注冻结不再维护）
- [x] 6.3 本地全测试绿 → openspec archive
