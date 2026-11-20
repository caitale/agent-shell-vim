# Proposal

## Why

M0–M3 交付了完整但"素"的工作流：输入区没有 @文件//斜杠补全（多打字）、busy 时无排队机制（并发发出的 prompt 被 agent 侧报错，重试靠手动）、token 消耗不可见（M1 只渲染单次 usage 行）、权限模式只能靠 agent 侧约定、图片无法发给 agent。M4 把日常使用的高频摩擦逐个消除——这是"能用来做真正工作"的一轮。

## What Changes

- **输入区补全**：输入区 insert 模式补全——`@` 触发文件路径补全（相对 cwd 递归 glob，`complete()` 原生菜单）、`/` 行首触发斜杠命令补全（数据源 `available_commands_update` 缓存的命令表）
- **prompt 队列**：busy 时发送的 prompt 进入本地队列（FIFO，上限可配 `g:agent_shell_queue_max` 默认 5），轮次结束（stopReason/error/权限拒绝）自动依序发下一条；队列非空时聊天提示 `[QUEUE] 待发 N 条`
- **成本显示**：累计 usage_update 的 token 计数（input/output 分开累计，跨轮次），`:AgentUsage` 呈现本会话累计 + 最近一轮；statusline busy 段附带简要 token 数
- **权限模式切换**：`:AgentMode [modeId]` 列出/切换（数据源 session/new 的 `modes.availableModes`；切换走 `session/set_mode`——实测可用）；`:AgentConfig` 展示 configOptions（含模型当前值与可选项——**模型切换无标准 RPC**（set_model -32601 实证），仅展示）
- **图片附件**：`:AgentImage <path>` 将图片（png/jpg/webp，≤2MB）读入 base64 追加到输入区待发内容（`{type:'image', data, mimeType}` block 与文本一起发送）
- **M3 余项**：登记表损坏重置断言补齐；真实桥 load 契约记档仍受 magpie 502 阻塞（继续挂起，不阻塞本 change）

## Capabilities

**New**：`input-completion`（@文件/斜杠补全行为）、`prompt-queue`（排队与自动依序发送）、`cost-display`（累计与呈现）、`mode-switch`（模式列表/切换/模型展示）、`image-attach`（图片读取与发送）

**Modified**：无。逐条对照：① chat-ui「常驻输入区」——补全/Tab 是 insert 路径增强，不触碰 `<CR>` 发送/防线/清空语义；② acp-session「轮次与 stopReason」——排队 prompt 也是用户 prompt，轮次定义不变；③ session-management「轮次进行中拒绝切换」——限 load/list/new，队列只动 prompt 路径不碰会话切换守卫。队列×换会话的 150ms 窗口是基线未覆盖的**新**行为组合，以 ADDED scenario 补进本 change（非 MODIFIED）。

## Impact

- **代码**：render.vim（输入区补全挂载）、session.vim（队列状态机/usage 累计/set_mode/image block 组包）、新 `autoload/agent_shell/complete.vim`（补全数据源）、plugin 命令（AgentUsage/AgentMode/AgentConfig/AgentImage）
- **wire 契约（实测 2026-11-20，/tmp/m4_probe*.jsonl）**：session/new result 含 `modes:{currentModeId,availableModes[]}` 与 `configOptions[{id:'mode'|'model',currentValue,options[]}]`；`session/set_mode {sessionId,modeId}` → `{}`；`session/set_model` **-32601 不存在**；image block `{type:'image', data:<base64>, mimeType}`（ACP 标准）
- **测试**：mock 补 usage_update 携带累积语义、available_commands、图片接受回显；断言覆盖队列/累计/补全数据/模式切换 RPC 形状
- **风险**：complete() 在 headless 不可交互——补全走手动调用路径断言数据源；图片大文件 base64 性能（2MB 上限）
