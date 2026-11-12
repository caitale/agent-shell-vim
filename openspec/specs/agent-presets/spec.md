# agent-presets Specification

## Purpose
TBD - created by archiving change add-plugin-skeleton. Update Purpose after archive.

## Requirements

### Requirement: 内置 preset

插件内置三个 agent preset：`mock`（随插件分发的 mock agent，测试基准，仅需 python3）、`claude`（claude-agent-acp 适配器）、`pi`（pi-acp，即 @geohar/pi-acp 桥）。preset 只包含启动命令与展示名，不包含、不管理任何凭证（凭证与路由全部由 agent 侧自行处理）。

#### Scenario: 三 preset 可启动

- **WHEN** 在干净环境变量下分别以 `:AgentStart mock` / `:AgentStart claude` / `:AgentStart pi` 启动且对应 CLI 在 PATH
- **THEN** 三个 preset 均完成握手并进入可用会话状态

#### Scenario: mock 无需外部依赖

- **WHEN** 机器只有 Vim 与 python3
- **THEN** `:AgentStart mock` 完整可用（协议闭环不依赖任何真实 agent CLI）

### Requirement: preset 选择与未知 preset 报错

`:AgentStart` 无参数时使用默认 preset（mock）；带参数时按名查找。未知名称给出包含可用 preset 清单的错误提示，不启动任何进程。

#### Scenario: 默认 preset

- **WHEN** 执行 `:AgentStart`（无参数）
- **THEN** 以默认 preset（mock）启动

#### Scenario: 未知名称

- **WHEN** 执行 `:AgentStart foo`（不存在的名称）
- **THEN** 报错并列出全部可用 preset 名，无子进程产生

### Requirement: 用户自定义 preset

用户通过全局配置变量以相同结构声明自定义 agent（名称 + 启动命令 list），与内置 preset 同等可用；与内置同名时用户定义优先。选择 preset 的时机在启动前，启动后切换需先停止。

#### Scenario: 自定义 agent 接入

- **WHEN** 用户在配置中声明 `myagent` → 启动命令 list，执行 `:AgentStart myagent`
- **THEN** 该命令被用于 spawn，行为与内置 preset 一致

#### Scenario: 覆盖内置

- **WHEN** 用户定义与内置同名的 preset
- **THEN** 使用用户定义的启动命令
