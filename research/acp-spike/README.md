# ACP Vim Spike — 协议闭环验证（调研资料）

> 本目录属于 `research/` 调研资料，验证「狭义 Vim (9.2) 实现 ACP 客户端」的可行性。**结论：可行，已跑通完整协议闭环（mock 与真实 agent 双验证）。** 正式插件代码不在此目录开发。

## 文件

| 文件 | 说明 |
|---|---|
| `mock_agent.py` | Mock ACP agent：JSON-RPC 2.0 over stdio（换行分隔 JSON），纯 Python 标准库，无 SDK 依赖 |
| `acp.vim` | Vim9 最小 ACP 客户端：job/stdio 驱动 mock agent，含聊天 buffer、流式渲染、权限审批 |
| `test_acp.vim` | headless 集成测试（主流程 7 项断言） |

## 已验证的协议闭环

```
initialize → session/new → session/prompt
  ├─ session/update: user_message_chunk / plan / tool_call / agent_message_chunk（流式）
  ├─ session/request_permission（agent→client 反向请求）→ 用户 y/n 答复
  │    ├─ 允许 → 工具执行 → 流式回复 → stopReason=end_turn
  │    └─ 拒绝 → stopReason=refusal
```

## 测试结果

- 主流程（headless `vim -es`，mock agent）：**7/7 PASS**
- 权限拒绝分支：**2/2 PASS**（stopReason=refusal 正确返回）
- **真实 agent（claude-agent-acp）冒烟：3/3 PASS**——握手建会话、单轮问答（`[AI] pong`）、end_turn

## 真实 agent 对接（2026-11-10 实测）

**Claude Code 本体不说 ACP**，官方路径是适配器 `@zed-industries/claude-agent-acp`（现更名 `@agentclientprotocol/claude-agent-acp`，v0.102.0）：

```bash
npm install -g @agentclientprotocol/claude-agent-acp
```

```vim
:let g:acp_agent_cmd = ['claude-agent-acp']
:AcpStart
:AcpSend reply with exactly the word: pong
```

pi coding agent（1.5.0）**本体无 ACP 支持**——其 `--mode rpc` 是自有 JSONL 协议（command/response/session-event 三类记录）。但社区有 ACP 桥，两个均已实测（2026-11-10）：

**✅ 推荐：`@geohar/pi-acp`（v0.4.0，`npm i -g @geohar/pi-acp`，bin 亦为 `pi-acp`）——本机实测通过，当前默认**

- 定位：svkozak/pi-acp 的**活跃 fork**（upstream 0.0.34 停更于 2026-09，geohar 0.4.0 发于 2026-11-04，周下载 ~1.3k）。同为 spawn `pi --mode rpc` 子进程架构，**继承 pi CLI 全部行为**（含 `models.json` 自定义 provider/magpie 本地代理）。
- fork 增量：**pi-subagents 舰队 → ACP plan/tasks 通道**（本机 pi 恰装有 pi-subagents，直接受益）、MCP 自动配置（mcpServers → 生成 `.pi/mcp.json`）、多根工作区（additionalDirectories）、session/resume + close、向 ACP v2 演进。
- 实测链路（2026-11-10）：initialize → session/new → GLM-5.3 回复 `pong` → end_turn ✅；edit 工具输出结构化 diff（oldText/newText）+ 行号推断，对 Vim 端 diff 审查功能直接有用。
- **坑（与 svkozak 相同）**：必须 `env -u NODE_OPTIONS` 启动，否则内部 pi 子进程 trust 锁崩溃（stream destroyed）。

**备选：`svkozak/pi-acp`（v0.0.34，unscoped `pi-acp`）——本机实测通过，胜在极简**

- 同架构（spawn 真 pi 子进程），实测 pong 闭环 ✅，update 流多观测到 agent_thought_chunk / usage_update。
- 但 2026-09 后无更新；MCP 需手动配、无 subagent→plan 映射、无 v2 能力。仅当追求"上游原版/最小依赖"时选它。

**选型结论（agent-shell-vim 场景）**：选 **geohar fork**——它把「pi 扩展生态」（本机已有 pi-subagents）桥进 ACP，且 edit diff 结构化与正式插件规划的 vimdiff 审查直接对齐；svkozak 作为上游兜底，openma 桥（SDK 进程内）因不认自定义 provider 出局。

**⚠️ 不推荐（当前场景）：`@openma/pi-acp`（v0.1.8，pi SDK 进程内）**

- initialize 握手成功且能力面最完整，但**不认 `models.json` 自定义 provider**（magpie 本地代理）——session/new 恿报 -32000 "no model is available"，即 CLI 直连正常、桥内不可用。
- 只用官方 provider（anthropic/openai/google…）时可能没问题；自定义 provider 用户选 spawn 型桥。

其余 fork（@ccgv2 / @razorbackdb / @hobby0524 / @automatalabs 等）活跃度或场景不匹配，未测。

**接入方式（geohar 桥）**：

```vim
" NODE_OPTIONS shim 环境下需 strip；普通终端无需此行
let g:acp_agent_cmd = ['env', '-u', 'NODE_OPTIONS', 'pi-acp']
```

### 第三方 API（auth token 路径）验证（2026-11-11）

本机 claude CLI **非官方订阅**，走第三方协议兼容 API：`ANTHROPIC_BASE_URL=http://127.0.0.1:3425`（magpie 本地代理）+ `ANTHROPIC_AUTH_TOKEN`，模型映射 `zcode/GLM-5.3`（与 pi 同一代理）。**结论：无影响，ACP 链路完全透明**——适配器 spawn claude CLI，CLI 自行读取 env 完成认证与路由，ACP 层只搬运 JSON-RPC。

- 复跑冒烟 3/3 PASS（`pong`、end_turn、usage 正常），此时实际模型已是 GLM-5.3
- 回看 11-10 首次冒烟（当时配置相同）：同样走第三方路径成功，即"claude 冒烟"自始就是第三方 API 验证
- **对插件设计的启示**：凭证与路由全在 agent 侧（CLI env / 桥），ACP 客户端无需任何 provider 感知——这正是 ACP vendor-neutral 设计的兑现。M0 的 preset 只需存启动命令，不碰凭证

### 对拍发现（mock vs 真实 wire format 差异）

| 差异点 | mock 旧版（想当然） | 真实 ACP（claude-agent-acp 实测） |
|---|---|---|
| update 容器 | `params.sessionUpdate` | **`params.update`** |
| update 判别字段 | `sessionUpdateType` | **`update.sessionUpdate`** |
| `session/new` params | 可省 mcpServers | **必须带 `mcpServers: []`**（zod 校验，否则 -32602） |
| `session/new` 响应 | 仅 sessionId | 附带 `modes` / `configOptions` |
| 诊断日志 | 无 | 走 stderr（`[session/create]` 等），客户端应降噪 |
| 额外通知 | 无 | `_auth/status_update`、`available_commands_update` 等 |

mock_agent.py 已对齐真实 wire format，客户端 `HandleUpdate` 同步切换到 `params.update.sessionUpdate` 判别。**教训：spike 阶段的 mock 必须尽早与至少一个真实实现互测，纯自研 mock 的字段命名会漂移。**

调试开关：`g:acp_debug`（原始 JSONL 落盘路径）、`g:acp_verbose`（显示适配器 stderr）。

## 运行方式

```vim
:source acp.vim
:AcpStart            " 启动并握手
:AcpOpen             " 打开聊天 buffer
" 写一行消息按 <CR> 发送；权限请求按 y / n
:AcpSend hello       " 或脚本化发送
:AcpStop
```

headless 测试：`vim -Nu NONE -n -es -S test_acp.vim -c 'qa!'`

## 架构结论（对应调研报告）

1. **可行性已实证**：仅用 Vim 内建 `job_start` + `ch_sendraw` + `json_encode/decode` 即可完成 ACP 客户端协议层，零外部依赖。
2. **本项目验证的是「Vim 直连」路径**；若协议面扩大（elicitation、MCP 下发、多 agent），建议切到 sidecar 架构（Rust/Python 协议核心 + Vim 薄 UI），hermes.nvim 即此模式。
3. mock agent 即 ACP 服务端语义参考：实现新 agent 适配时可直接对拍。

## 方言与平台决策（2026-11-10）

**决策：坚持 vim9script，只支持狭义 Vim 9.x，不做 Neovim 兼容。**

理由：

1. **生态空位**：Neovim 端已有 agent.nvim / hermes.nvim / CodeCompanion / LouiseLM 等多个 ACP 客户端，Vim 端为零——本项目的差异化价值就是「让 Vim 用户用上 ACP」。
2. Neovim 官方章程明确将 "Support Vim9script" 列为 Non-goal，转投 Neovim 等于重写客户端并与存量插件同质竞争。
3. 双端兼容的两条路均有代价：降级 legacy VimL 损失 Vim9 的性能与类型检查；Lua 共享核心 + 双绑定受制于 Vim 端 `+lua` 覆盖率与 Lua 版本漂移（实测本机 Vim 链接 Lua 5.5，Neovim 为 LuaJIT/5.1，且 Vim 的 Lua 无 job/异步 API）。

Neovim 用户请直接使用 agent.nvim（带聊天 UI）或 hermes.nvim（协议层 sidecar）。若日后协议面显著扩大（elicitation / MCP 下发 / 多 agent），可重新评估 sidecar 架构（hermes.nvim 即此模式）。

## 踩坑记录（Vim9 移植相关）

| 坑 | 现象 | 修复 |
|---|---|---|
| `command! Foo () => Bar()` | lambda 被求值但**不调用**，静默 no-op | 用 `command! Foo call Bar()` |
| 插值字符串中字面 `{` | E1279 Missing '}' | 改用 `..` 拼接 |
| headless 下 `:new`/`:split` | 静默不创建 buffer | 用 `bufadd()` + `bufload()` |
| 命令与 def 同名跨脚本调用 | E117 Unknown function | 命令名与函数名解耦 |

## 下一步（若要做成正式插件）

1. 真实 agent 接入：`claude-agent-acp` / `gemini --experimental-acp`（mock → 真实对拍）
2. diff 审查：session/update 的 `tool_call` content 中 diff → vimdiff 展示 + 接受/拒绝
3. 折叠 UI：工具调用/思考块用 `foldmethod=marker` 降级实现
4. @文件补全、/斜杠命令补全（ACP 协议里有对应方法）
