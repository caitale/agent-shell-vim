# Proposal

## Why

M0–M2 交付了"单会话、一次性的"完整体验，但 Vim 重启或 `:AgentStop` 后对话即丢；用户也无法在多个任务线索间切换。竞品 agentic.nvim 的招牌特性正是会话持久化与编辑器↔终端互通（终端里开的 claude 会话拉回编辑器继续）。M3 补上会话生命周期管理，是插件从"能用"到"可日常依赖"的关键一步。

## What Changes

- **会话列表**：`:AgentSessionList` 调用 `session/list` RPC，在聊天 buffer 中渲染历史会话列表（标题/时间/cwd/sessionId），带 `nextCursor` 翻页处理
- **会话恢复**：`:AgentSessionLoad [n]`（列表序号）向**当前运行的 agent** 发送 `session/load`（含原会话 cwd），恢复后 sessionId 替换为加载的会话，聊天 buffer 记录恢复来源；`:AgentStop` 后需先 `:AgentStart` 再 load
- **切换语义（多会话）**：`:AgentSessionNew` 新建会话（同一 agent 进程内 session/new），`:AgentSessionCurrent` 显示当前会话信息——进程单实例但会话可切换（M3 不做多进程并行，见 Non-Goals）
- **本地会话登记**：插件维护最近使用会话登记表（persist 到 `~/.cache/agent-shell-vim/sessions.json`，记录 preset/sessionId/title/lastUsed），`:AgentSessionLoad` 无参时从登记表取最近一条恢复（登记表空则提示并引导 `:AgentSessionList`；agent 未运行时按登记 preset 自动启动后加载）
- **mock 夹具扩展**：session/list 返回固定两条 + session/load 校验 sessionId 并回放一条确认消息（测试夹具对齐两桥契约）
- **BREAKING**：无（全部新增命令与行为）

## Capabilities

**New Capabilities**：

- `session-management`：会话列表呈现、恢复加载、新建切换、本地登记与跨启动恢复（全部可观察行为）

**Modified Capabilities**：无（acp-session 的握手/轮次语义不变；session/load 只是新的 RPC 消费方，属 transport 既有分帧能力内）。

## Impact

- **代码**：session.vim（list/load/new 的 RPC 发送与响应处理）；新增 `autoload/agent_shell/sessions.vim`（列表状态/登记表/选择器）；render.vim（列表渲染与序号行定位）；plugin 入口四命令
- **wire 契约（两桥实测 2026-11-20）**：`session/list` → `{sessions:[{sessionId,cwd,title,updatedAt}], nextCursor?}`；`session/load` params `{sessionId, cwd, mcpServers:[]}`，响应含新 sessionId（claude 桥 UUID 校验）
- **测试**：mock 夹具扩展 + 新断言（list 渲染/load 恢复/登记表持久化）；真实桥冒烟（claude list + load 一条真实历史会话）
- **风险**：pi 桥 load 后的 sessionId 语义（是否新 id）需冒烟实测；登记表与真实会话漂移（外部删除）时 load 失败的降级提示
