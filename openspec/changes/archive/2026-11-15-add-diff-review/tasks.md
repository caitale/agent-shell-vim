# Tasks: add-diff-review

## 1. diff 模块与捕获（wire 契约见 design「wire 契约」小节）

- [x] 1.1 新建 `autoload/agent_shell/diff.vim`：`OnToolEvent(upd)` 同时接收 tool_call 与 tool_call_update——toolCallId 合并（首见建壳）、diff 提取（content[].type=='diff'；path 兜底链 locations→rawInput.file_path）、kind 非 edit/write 且无 diff 不入队；vim9 范式遵循 session.vim 已验证写法（E1013/E1094 防复发）
- [x] 1.2 session.vim：HandleUpdate 的 tool_call 与 **tool_call_update**（M1 遗留：曾被静默丢弃）分支均转发 `diff.OnToolEvent(upd)`；时序定序：render.Update 先渲染、diff.OnToolEvent 后入队打标
- [x] 1.3 render.vim：Update 补 tool_call_update 渲染（title 演进/状态行更新/参数不刷）；tool_call 渲染以 toolCallId 记 block 映射；`MarkToolCall(id, state)`（`（待审查）`/` ✓`/` ✗`；主路径映射定位，兜底 `▸ TOOL`+title 末次匹配）

## 2. 审查编排与接受/拒绝

- [x] 2.1 `diff.Review(idx)`（design D3 严格顺序）：tabnew → 校验 tabpagenr 增量（失败在任何注册前 return false）→ 右侧 checktime/打开（modified 则警告降级）→ 左侧只读 nofile buffer 写 oldText → windo diffthis → 左右两 buffer 注册 `]a`/`]r`/`]n` 并记录 review_bufs 清单
- [x] 2.2 `diff.Accept()`（active_idx 规则：Review 设定，未设定=首个 pending，操作后清除）：state='accepted'、render 标记、Teardown（清映射→关 tab→回聊天窗）、chain 开启时 Review(next)
- [x] 2.3 `diff.Reject()`：Norm 规范化比对（join/split 统一，末尾换行声明）；一致→writefile(old_text)+checktime 刷新（modified buffer 警告降级）+上下文失真提示行；不一致→警告且 state 不变；oldText 空→警告人工处理；Teardown 同上
- [x] 2.4 `diff.Next()` / `diff.Status()`：跳下一待审查项 / 队列列表呈现

## 3. 命令与配置

- [x] 3.1 plugin 入口：`:AgentDiffReview [n]`（-nargs=?，无参=首个待审查）、`:AgentDiffAccept`、`:AgentDiffReject`、`:AgentDiffNext`、`:AgentDiffStatus`
- [x] 3.2 配置：`g:agent_shell_diff_auto`（edit completed 且有窗口时自动 Review）、`g:agent_shell_diff_chain`（审查完自动下一项）；README 注释补全
- [x] 3.3 render.vim：TOOL 折叠块 buffer-local 映射补 `d`（转发 Review 该块对应条目）

## 4. mock 夹具扩展

- [x] 4.1 mock_agent.py：prompt 含 "edit" 时按 wire 契约发完整六事件（pending tool_call → locations update → 参数 update → diff content update → completed），**python 侧同步将 newText 写入 `/tmp/agent_shell_edit_test.txt`**（模拟 agent 落盘）；grep 路径保持不动

## 5. 测试

- [x] 5.1 既有 22 断言回归绿（夹具变更零破坏验证）
- [x] 5.2 新断言：捕获（edit 六事件→单条目含 diff/非 edit 不入队/同 id 合并）——经 `agent_shell#diff#Status()` 返回 list<dict> 观测
- [x] 5.3 新断言：接受语义（文件内容不变、state=accepted、标记出现）
- [x] 5.4 新断言：拒绝语义（一致时恢复 oldText；不一致时不写回+警告+待审查保持）
- [x] 5.5 新断言：headless 下 Review() 安全返回（不炸）；队列顺序与 Next 跳转
- [x] 5.6 `./t/run.sh` 全绿（两连跑稳定）；真实 agent 冒烟（claude 让它改一个文件，手动走 d→vimdiff→接受/拒绝——手动清单项）

## 6. 文档与归档

- [x] 6.1 README：审查工作流章节（d 键/命令/语义/配置）、命令表与配置表补全
- [x] 6.2 openspec validate + spec 场景核对（自动断言映射 + 手动清单：vimdiff 视觉/映射/回跳/自动弹出）
- [x] 6.3 提交 → archive
- [x] 6.4 （归档后补充）verify-after-archive：三维验证 PASS with warnings，W-1/W-4 已修，勘误见 ERRATA.md
