# agent-shell.vim

**为狭义 Vim（9.1+）实现 ACP（Agent Client Protocol）客户端**——像 Zed / Emacs agent-shell / Neovim agentic.nvim 那样，在编辑器内与任意 ACP agent（Claude Code、pi coding agent、Gemini CLI 等）对话。

- 纯 vim9script，零外部依赖（仅 Vim 内建 `job_start` / `json_encode`）
- 不做 Neovim 兼容（Neovim 用户推荐 [agentic.nvim](https://github.com/carlos-algms/agentic.nvim) 或 [hermes.nvim](https://github.com/Ruddickmg/hermes.nvim)）
- 协议闭环经三 agent 实测：mock / claude-agent-acp / pi（@geohar/pi-acp 桥）

## 安装

```vim
" vim-plug
Plug 'caitale/agent-shell-vim'
" 或 minpac / 内建 packages：标准 plugin/ + autoload/ 布局均可
```

要求：Vim 9.1+，`+job`（huge 版默认有）；mock agent 另需 python3。

## 快速开始

```vim
:AgentStart          " 启动默认 preset（mock）并握手
:AgentOpen right     " 右侧垂直分割打开聊天窗口（默认 bottom 底部分割）
" 聊天 buffer 尾部是常驻输入区（── input ── 分隔线之下）：
"   多行编辑后按 <CR> 发送（normal/insert 模式均可）
"   换行方式：粘贴多行，或 insert 模式 <C-V><CR>
" 权限请求到达后按 y（允许）/ n（拒绝）
:AgentSend hello     " 脚本化发送（不经输入区）
:AgentStop
```

## 改动审查（M2）

agent 修改文件后，改动进入待审查队列，聊天中的 TOOL 折叠块显示状态标记（待审查 / ✓ / ✗）：

```vim
:AgentOpen            " 有新改动后，在 TOOL 折叠块上按 d 打开 vimdiff 审查
                      "   审查 tab 内：]a 接受、]r 拒绝、]n 下一项
:AgentDiffReview      " 打开第一个待审查项（或 :AgentDiffReview 2 指定序号）
:AgentDiffAccept      " 接受：保持文件现状（agent 的修改生效）
:AgentDiffReject      " 拒绝：文件恢复为改动前内容（校验一致才写回）
:AgentDiffNext        " 跳到下一个待审查项
:AgentDiffStatus      " 列出全部审查条目与状态
```

注意：拒绝是本地回滚，agent 上下文仍认为修改成功——请在其后的对话中告知它（聊天中也会有提示行）。文件在拒绝前若已被再次修改（与 newText 不一致），插件会拒绝写回并警告，转人工处理。

历史区请勿手改（行以 `[` 开头受发送防线保护，改了只影响显示不影响协议）。

## 内置 preset

| preset | 启动命令 | 凭证 | 说明 |
|---|---|---|---|
| `mock` | `python3 <plugin>/t/mock_agent.py` | 无 | 协议闭环测试基准，随插件分发 |
| `claude` | `claude-agent-acp` | claude CLI 自管 | `npm i -g @agentclientprotocol/claude-agent-acp` |
| `pi` | `pi-acp` | pi 自管 | `npm i -g @geohar/pi-acp`；需 pi 1.1+ |

## 自定义 agent

任意 ACP agent 一行接入（同名覆盖内置）：

```vim
let g:agent_shell_agents = {
  \ 'gemini': {'cmd': ['gemini', '--experimental-acp'], 'desc': 'Gemini CLI'},
  \ 'pi':    {'cmd': ['env', '-u', 'NODE_OPTIONS', 'pi-acp'], 'desc': 'pi（NODE_OPTIONS shim 环境）'},
  \ }
:AgentStart gemini
```

## 配置

| 变量 | 作用 | 默认 |
|---|---|---|
| `g:agent_shell_agents` | 自定义 preset 表（上） | `{}` |
| `g:agent_shell_verbose` | 非 0 透传 agent stderr（排障） | 0 |
| `g:agent_shell_debug` | 非空时原始 JSONL 双向落盘路径 | `''` |
| `g:agent_shell_layout` | 窗口布局：`'bottom'` \| `'right'` | `'bottom'` |
| `g:agent_shell_right_width` | right 布局宽度（列） | 46 |
| `g:agent_shell_bottom_height` | bottom 布局高度（行） | 12 |
| `g:agent_shell_highlight` | 消息类型高亮开关 | 1 |
| `g:agent_shell_diff_auto` | edit 完成自动打开 vimdiff 审查 | 0 |
| `g:agent_shell_diff_chain` | 审查完自动跳下一待审查项 | 0 |

UI 说明：轮次进行中聊天窗口状态行显示旋转 busy 指示；工具调用渲染为折叠块（自定义 marker `«as»`，`zo/zc` 开合）。

## 测试

```sh
./t/run.sh        # headless 全链路（33 断言，零 token）
# 真实 agent 冒烟（手动，耗 token）：
vim -Nu NONE -n -es -c 'let g:agent_shell_smoke = "claude"' -S t/smoke_real.vim -c 'qa!'
```

CI：GitHub Actions，Vim 9.1/9.2 矩阵（`.github/workflows/test.yml`）。

## Roadmap

M0 骨架 ✅ → M1 聊天 + UI 基线 ✅ → M2 diff 审查 ✅（vimdiff/接受/拒绝）→ M3 会话管理（list/load/resume，编辑器↔终端互通）→ M4 生产化（@文件与 /命令补全、队列、成本、图片附件）→ M5 差异化（traffic 回放测试、steering、图片预览）。详见 `research/competitive-analysis/`。

## 目录

```
plugin/agent-shell.vim        入口：命令与配置
autoload/agent_shell/         protocol / session / render / presets / diff 五模块
t/                            headless 测试 + mock 夹具 + 手动冒烟
research/                     调研资料（spike、竞品分析、roadmap）
openspec/                     spec 驱动开发的变更与规格
```
