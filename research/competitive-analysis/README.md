# 竞品分析与 Roadmap — 调研资料

> 本目录属于 `research/` 调研资料。调研对象：ACP（Agent Client Protocol）编辑器客户端的三个生态位（Emacs / Neovim / Vim），结论用于指导 agent-shell-vim 的正式插件规划。调研时间：2026-11-10。

## 一、竞品格局总览

| 生态 | 插件 | 星标 | 状态 | 定位 |
|---|---|---|---|---|
| Emacs | **xenodium/agent-shell** | ⭐2045 | 活跃（日更级） | **全生态标杆**：comint shell + viewport 双范式 UI |
| Neovim | **carlos-algms/agentic.nvim** | ⭐658 | 活跃 | **Neovim 事实标杆**：ACP 聊天侧边栏 |
| Neovim | Ruddickmg/hermes.nvim | ⭐6 | 活跃 | 协议层 sidecar（Rust + 官方 ACP SDK），无 UI |
| Neovim | kyza agent.nvim 等 | ~0 | 边缘 | 可忽略（曾误认为对标，已修正） |
| **Vim** | — | — | — | **空位，即本项目** |

## 二、标杆功能对照

### Emacs agent-shell（⭐2045）

- **23 个 ACP agent**（Claude/Codex/Gemini/Goose/Junie/OpenClaw…），vendor-neutral
- **双 UI 范式**：comint 式 shell buffer（REPL）+ viewport（view 只读导航 `[n/m]` / edit 多行 Markdown 组稿）
- **Fragment 渲染引擎**：工具调用/思考的可折叠交互块（activity grouping）
- **diff 审查**：独立 viewer，unified diff + 接受/拒绝
- **steering 中途转向**（0.78+）：`_session/steering` 扩展，M-RET 不中断轮次改方向；普通 RET 排队，队列合并成一个 turn
- **持久 prompt**：buffer 尾部常驻可写输入区，busy 动画
- **成本/用量**：header line 显示 token/费用
- **生态**：sidebar / bookmark / workspace-manager / org-babel / TRAMP / dashboard / 自定义 markdown 渲染器（LaTeX→SVG）
- **traffic 落盘 + 回放 fake agent**：零 token 确定性测试

### Neovim agentic.nvim（⭐658）

- **12+ ACP provider**（Claude/Gemini/Codex/OpenCode/Cursor/Copilot/Goose/**Pi**/Kiro/Cline…），复用终端 CLI 的登录与配置（零凭证管理）
- **会话互通**（招牌）：sessions 为 provider 原生，Neovim ↔ 终端互相继续对话
- **权限审批**：仿 Claude Code 数字键一键审批（1/2/3…）
- **模型切换**（`m`）、**provider 中途切换不丢历史**（`s`）、**agent 模式切换**（Shift-Tab：Default/Auto-Accept/Plan）
- **富 diff 预览**：side-by-side / inline，布局可旋转
- **@文件模糊补全** + **/斜杠命令原生补全**
- **图片**：拖拽/粘贴截图（依赖 img-clip.nvim + image.nvim）
- **多会话并行**：每 tab 独立 agent，窗口关闭后台继续
- Neovim 0.11+；"界面归插件、智能归 agent"，无 hidden prompt

### 空白点（没人做 → 我们的机会）

- **Vim 端整体空位**（核心定位）
- steering 中途转向：仅 Emacs 有，Neovim 端无人做
- traffic 回放测试：仅 Emacs 有

## 三、功能差距矩阵（三方）

| 功能 | Emacs agent-shell | Neovim agentic.nvim | 我们（计划） |
|---|---|---|---|
| 多 ACP agent | ✅ 23 | ✅ 12+ | ✅ 3 已实测（mock/claude/pi-geohar） |
| 会话互通（编辑器↔终端） | ✅ | ✅ 招牌 | M3（桥均支持 session/list） |
| 权限审批 | ✅ | ✅ 数字键 | ✅ y/n 已验证 |
| diff 审查 | ✅ 独立 viewer | ✅ ss/inline | M2 vimdiff（geohar 桥给结构化 diff） |
| 模式/模型中途切换 | ✅ | ✅ m/s/Shift-Tab | M4（configOptions 已在流里） |
| 折叠（fragment） | ✅ | 部分 | M1 foldmethod=marker 降级 |
| prompt 队列/合并 | ✅ | ✅ | M4 |
| 成本显示 | ✅ | ❌ | M4（usage_update 已在流里） |
| 图片输入 | ✅ | ✅ | M4 附件 / M5 预览（见下） |
| steering | ✅ 独有 | ❌ | M5 差异化 |
| traffic 回放测试 | ✅ 独有 | ❌ | M5（mock_agent.py 是种子） |

## 四、Roadmap（M0–M5）

| 里程碑 | 内容 | spike 现状 |
|---|---|---|
| **M0 骨架** | `plugin/` + vim9script `import autoload` 模块化；三 agent preset（mock / claude-agent-acp / pi-geohar 桥）；headless 测试迁移 | 协议层已验证 ✅ |
| **M1 可用聊天** | 聊天 buffer；流式渲染全类型（message / thought / tool_call / usage / plan）；权限 y/n；折叠降级（`foldmethod=marker`） | 渲染雏形 ✅ |
| **M2 diff 审查** | 结构化 diff（oldText/newText）→ vimdiff 展示 + 接受/拒绝 | README 已规划 |
| **M3 会话管理** | session/list / load / resume；多会话切换；编辑器↔终端会话互通 | 桥能力已确认 |
| **M4 生产化** | @文件 / /斜杠补全（available_commands_update 已在采集）；prompt 队列；成本显示；模型/模式切换；**图片附件**（base64 → ACP image block，纯数据操作，无需图形协议） | 数据源已在流里 |
| **M5 差异化** | **traffic 回放测试**（零 token CI，抄 agent-shell 思路）；**steering**（`_session/steering`）；图片预览探索 | 渐进 |

### 图片输入的技术拆解（M4/M5 边界）

- **附件（M4，便宜）**：图片路径 → base64 → ACP image block 发送。与终端无关，Vim script 可直接实现。
- **预览（M5，探索性）**：Vim 是 TUI，无画像素能力，唯一路径是 **Kitty Graphics Protocol**（`<ESC>_G` APC 转义序列，终端代渲染）。支持：Kitty/WezTerm/ghostty/Konsole（iTerm2 走自己的 OSC 1337 分支）；tmux 需 `allow-passthrough`。**Vim 无 extmarks 等价物，滚动时图像会错位**——只能固定区域显示或手动刷新，是明确的降级体验，故归 M5。

## 五、对本项目的定位结论

1. **对标 agent-shell（Emacs），不是 Neovim 插件**——功能面参考系以 Emacs 标杆为准，agentic.nvim 提供交互细节参照（数字键审批、模式切换、会话互通）。
2. **M0–M2 的"协议 + 聊天 + 权限 + diff"是两个标杆共有的最小核心**，优先做扎实。
3. **差异化三支点**：Vim 端唯一（蓝海）、traffic 回放测试、steering。
4. Vim modal 特性可做自己的交互：normal 模式 y/n 审批、visual 选区组稿 prompt。
