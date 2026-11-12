# Design: add-plugin-skeleton

## Context

spike（`research/acp-spike/acp.vim`，单文件 197 行）已验证全部协议行为；本设计只回答"如何把它拆成 vim9script 模块化插件而不丢任何已验证行为"。约束：Vim 9.1+ 单端、零外部依赖、headless 测试可跑（`vim -Nu NONE -n -es`）。

## Goals / Non-Goals

**Goals**：模块边界清晰（协议/会话/渲染/preset 四分）；spike 全部行为等价迁移；CI 从第一天保护回归；M1 的 UI 基线有挂载点。

**Non-Goals**：不新增功能（折叠/布局/补全等属 M1+）；不做插件管理器适配（vim-plug/minpac 均原生支持 plugin/+autoload/ 布局，无需特判）；不做 vim9script linter 引入（vint 支持不全，`:def` 编译期检查即静态检查）。

## Decisions

### D1：模块划分与状态归属

```
plugin/agent-shell.vim          命令 + 默认配置（薄入口，无逻辑）
autoload/agent_shell/
  protocol.vim   job 句柄、分帧、id 计数、Send/Raw 落盘、stderr 策略
  session.vim    sessionId、permId 挂起、握手序列、prompt 组包、OnMessage 分发
  render.vim     聊天 buffer（bufadd 无窗口依赖）、update 类型渲染、Log
  presets.vim    preset 表（内置三 + 用户表合并）
t/  test_protocol_session.vim + mock_agent.py + run.sh
```

状态归属原则：**job 归 protocol，会话语义状态归 session，buffer 归 render**——与 spike 中自然形成的分层一致，无跨层状态倒挂。

- 备选否决：单文件加 `import`（等于 spike 换皮，M1 会立刻膨胀）；每模块自持 job（多会话 M3 才需要，现在过度设计）。

### D2：模块间通信 —— session 持有分发权

protocol 收到行后回调 `session.OnLine(line)`；session 解析后调 `render.X()`。即**单向依赖 session → {protocol, render}**，render 不依赖任何模块（纯函数性质）。presets 只被 plugin 入口消费。

规避 spike 踩坑清单：**命令定义一律 `command! X call Func()` 形式，禁止 lambda 内联**（spike 实证 lambda 命令静默 no-op）；命令与 def 解耦命名；跨脚本调用走 `import autoload`，不用 `:call` 字符串；插值字符串避免字面 `{`（用 `..` 拼接）。

**例外说明**：protocol 的 stderr 透传在 verbose 模式下直接调 render（protocol→render 单向边），这是唯一的非 session 中转边，无环，属设计内例外。

### D3：import autoload 的路径与兼容写法

Vim 9.1 的 `import autoload '...'` 相对 plugin/ 与 autoload/ 解析。**决策：所有模块（含 plugin 入口对四模块）统一使用 `import autoload '../autoload/agent_shell/xxx.vim'` 形式的显式相对路径**（入口位于 plugin/ 下，`..` 回到插件根再进 autoload；模块间位于同级目录用 `./xxx.vim`），最稳，避免 runtimepath 解析差异，9.1/9.2 CI 矩阵正好护住这一点。回调注册用具名 def 函数 + 薄 lambda 转发（spike 已验证 job_start 回调 lambda 可行）。

**headless 测试加载**：`vim -Nu NONE` 下 runtimepath 为空，测试脚本必须先 `set rtp^=<插件根>` 再 source 入口（run.sh 固化此步骤）；插件正常运行时经 rtp 由 Vim 自动加载 plugin/ 入口，两条路径都只依赖标准 plugin/autoload 布局。

### D4：preset 数据结构

```vim
# 每项：{cmd: list<string>, desc: string}
mock:   ['python3', '<plugin_root>/t/mock_agent.py']  # 运行时定位
claude: ['claude-agent-acp']
pi:     ['pi-acp']
```

`<plugin_root>` 用 `expand('<sfile>:h:h')` 类运行时定位（不写绝对路径——spike 的迁移失效教训）。用户表 `g:agent_shell_agents` 浅合并进内置表（同名覆盖）。pi 的 `env -u NODE_OPTIONS` **不进默认 preset**：那是本机 WorkBuddy shim 特例，写进 doc 作为用户自定义示例。

### D5：测试与 CI

- `t/run.sh`：`vim -Nu NONE -n -es -S test_protocol_session.vim -c 'qa!'`，断言写 /tmp 结果文件（沿用 spike 范式）；mock 主流程 7 断言 + 拒绝分支 2 断言全部迁移。
- 测试 source 的是 **plugin 入口**（非直接 source autoload 单文件），保证整链路（命令→preset→协议→渲染）被测。
- CI：action-setup-vim 装 9.1/9.2 → 跑 `t/run.sh`。首跑预期暴露 vim9script 版本差异，属设计内收益。

### D6：M1 挂载点（预留不实现）

render.vim 留 `OnInputArea()` 空挂载点与 buffer 末尾输入区标记约定；plugin 命令预留 `:AgentOpen [right|bottom]` 的参数解析位。仅占位，无行为。

## Risks / Trade-offs

- [vim9script 9.1/9.2 行为差异导致 CI 红] → 矩阵跑同一套断言；差异在 design 层面预期，修复策略：面向 9.1 语法子集写代码
- [import autoload 跨文件 def 调用触发 E117（spike 踩坑）] → 模块间调用统一走 import 符号表；命令名与函数名彻底解耦
- [mock_agent.py 双份漂移（research/ 与 t/）] → t/ 为唯一真源；research/ 是冻结的历史资料，README 标注不再维护（此标注列入 tasks 6.2 的 README 更新范围）
- [单会话架构到 M3 多会话需重构] → 接受。state 收拢在 session.vim 模块级变量，M3 时改为字典按会话键控，边界不变

## Migration Plan

纯新增，无存量迁移。spike 的 `research/acp-spike/` 原样保留。回滚 = 删除 `plugin/ autoload/ t/ .github/` 新增目录，无副作用。

## Open Questions

无（全部技术决策已定；输入区具体形态属 M1 届时决策）。
