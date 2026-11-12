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
:AgentOpen           " 打开聊天窗口；写一行普通文本按 <CR> 发送
                     " 权限请求到达后按 y（允许）/ n（拒绝）
:AgentSend hello     " 脚本化发送
:AgentStop
```

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

## 测试

```sh
./t/run.sh        # headless 全链路（14 断言，零 token）
# 真实 agent 冒烟（手动，耗 token）：
vim -Nu NONE -n -es -c 'let g:agent_shell_smoke = "claude"' -S t/smoke_real.vim -c 'qa!'
```

CI：GitHub Actions，Vim 9.1/9.2 矩阵（`.github/workflows/test.yml`）。

## Roadmap

M0 骨架（当前）→ M1 聊天 + UI 基线（布局/输入区/高亮/折叠）→ M2 diff 审查（vimdiff）→ M3 会话管理（list/load/resume，编辑器↔终端互通）→ M4 生产化（@文件与 /命令补全、队列、成本、图片附件）→ M5 差异化（traffic 回放测试、steering、图片预览）。详见 `research/competitive-analysis/`。

## 目录

```
plugin/agent-shell.vim        入口：命令与配置
autoload/agent_shell/         protocol / session / render / presets 四模块
t/                            headless 测试 + mock 夹具 + 手动冒烟
research/                     调研资料（spike、竞品分析、roadmap）
openspec/                     spec 驱动开发的变更与规格
```
