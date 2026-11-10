# research/ — 调研与验证资料

存放项目正式开发前的调研、spike 与技术验证产物。**这里是资料区，不是插件源码区。**

## 目录索引

| 目录 | 内容 | 状态 |
|---|---|---|
| `acp-spike/` | ACP 协议闭环 spike：Vim9 最小客户端 + mock agent + headless 测试（7/7 PASS） | ✅ 已完成，结论可行 |

## acp-spike 核心结论（速览）

- 协议闭环跑通：`initialize → session/new → session/prompt`，含流式 update、权限审批（allow/refuse 分支）
- 方言决策：**vim9script、仅狭义 Vim 9.x、不做 Neovim 兼容**（详见 `acp-spike/README.md` 的决策章节）
- Vim9 踩坑速查表在 `acp-spike/README.md`，正式开发时直接复用

## 约定

- 新的调研/spike 按主题建子目录，各自带 README 记录结论
- 结论被正式开发采用后，源码进插件目录，本目录只留资料与决策记录
