# Design: add-diff-review

## Context

M1 已交付聊天 UI 基线（折叠块/输入区/busy）。M2 在 tool_call 渲染管线上加 diff 审查：捕获 → 队列 → vimdiff → 接受/拒绝。

## wire 契约（B1：claude-agent-acp 实测抓包，2026-11-14，/tmp/probe_all.jsonl）

edit 工具的完整事件序列（同一 toolCallId）：

```
1. tool_call          status=pending  title="Edit"(无路径) content=[] locations=[]
2. tool_call_update   rawInput={file_path}  title="Edit probe_target.txt"
                      locations=[{path:"/tmp/probe_target.txt"}]
3. tool_call_update   rawInput 参数逐步补全（new_string → +old_string → +replace_all）
4. tool_call_update   content=[{type:"diff", path, oldText:"beta", newText:"BETA-CHANGED"}]   ← 结构化 diff 在此
5. tool_call_update   _meta.toolResponse{originalFile, structuredPatch, ...}（适配器扩展，不依赖）
6. tool_call_update   status="completed" rawOutput="The file ... updated successfully."
```

**解析规则（判定伪码）**：

```
type == 'tool_call_update' 且 content 是 list：
  遍历 content，取 c.type == 'diff' 的条目 → {path: c.path, old: c.oldText, new: c.newText}
  path 兜底：locations[0].path → rawInput.file_path（皆绝对路径，实证）
title 仅作展示，不作路径来源（pending 阶段无路径，实证）
type == 'tool_call'（首个 pending）→ 仅初始化条目（kind=edit 时预建壳，等待 update 填充）
status 字段在 tool_call_update 上同步条目状态
```

**M1 遗留修正**：render.Update 未处理 `tool_call_update`（一直被静默丢弃）——本变更必须补上：折叠块标题/状态行按 update 事件演进（title 变化、参数补全不刷、completed 更新状态行）。

## Goals / Non-Goals

**Goals**：捕获零丢失（tool_call + tool_call_update 双事件合并）；拒绝写回一致性校验；headless 命令路径全断言；映射生命周期干净。

**Non-Goals**：partial accept（行级挑选，M5）；多文件合并视图；**改前 diff 预览审批（agentic 式）——审查不阻塞权限流，保持改后审路线**；diff 高亮主题。

## Decisions

### D1：diff 模块独立，单向被 session 调用

新增 `autoload/agent_shell/diff.vim`：`OnToolEvent(upd)`（session 转发 tool_call 与 tool_call_update 两种事件）→ 解析/合并/入队；`Review(idx)` / `Accept()` / `Reject()` / `Next()` / `Status()`（返回 `list<dict>`，测试可断言）。依赖：session → diff → render（标记）。diff 不回头调 session（审查动作不影响协议流）。

### D2：条目结构与合并

```vim
var pending: list<dict<any>>
# {id: toolCallId, path, old_text, new_text, state: 'pending'|'accepted'|'rejected',
#  title, status, block_id: 渲染标记锚}
```

- 同 id 合并：首见建壳（tool_call pending），update 到达时补 path（locations/rawInput 兜底链）与 diff content；diff 首见即定，不覆盖
- kind != edit/write 且无 diff content 的条目不入审查队列（但事件仍转发 render 渲染）
- **vim9 范式**：lambda 转发/顶层 import 遵循 session.vim 已验证写法（坑清单 E1013/E1094 防复发）

### D3：vimdiff 编排——tabpage 隔离 + 映射生命周期（B2 修正）

流程严格固化：

```
Review(idx):
  1. tabnew → 校验 tabpagenr('$') 增量；失败（headless）在任何注册动作之前 return false
  2. 右侧准备：文件已打开的 buffer 先 checktime；若 modified 则警告降级（不强刷，防 E37）；
     无 buffer 则直接打开文件
  3. 左侧：bufadd('agent-shell-diff-old://'+id) 只读 nofile，写入 old_text
  4. 左右 vertical split + windo diffthis
  5. 映射注册：对左右两个 buffer 各注册 ]a/]r/]n（buffer-local），记录 buffer 清单 review_bufs
  6. active_idx = idx
Teardown():
  对 review_bufs 逐一 nunmap <buffer> ]a/]r/]n → tabclose → 聚焦聊天窗
  （用户手动关 tab 的场景：Teardown 时 winnr 校验容错，映射仍清）
```

### D4：接受/拒绝语义（active_idx 规则 + 规范化比对）

- **active_idx**：Review 设定；Accept/Reject 无视图时 = 首个 state='pending' 条目；操作后清除
- **接受**：无文件操作，state='accepted'，render 标记 ✓
- **拒绝**：`Norm(s) = join(split(s, "\n"), "\n")` 两侧统一（末尾换行语义：写回统一以末尾换行结束；CRLF 声明不支持——readfile 默认吞 CR，README 注明）。比对 `Norm(readfile(path))` vs `Norm(new_text)`：
  - 一致 → `writefile(split(old_text,"\n"), path)` + 已打开 buffer `checktime` 刷新 + 聊天 buffer 记"[DIFF] 已恢复 {path}（agent 不知此回滚，下轮请告知）"
  - 不一致 → 警告入聊天 buffer，state 不变
  - old_text 为空 → 警告人工处理，state 不变（不做删除）
  - 原子性：不做原子写主张（writefile 直写；失败 catch 警告）
- **modified buffer 刷新降级**（W9）：拒绝写回后对该文件已打开 buffer checktime；若用户 buffer modified 则仅警告不强制 :e

### D5：状态标记——block_id 双锚

render 渲染 tool_call 折叠块时以 **toolCallId 为 key** 记录 `{id: block_lnum}` 映射（LogLines 追加在历史区尾部，旧块行号稳定不漂移——M1 结构实证；EnsureInputArea 重建场景走兜底）。`MarkToolCall(id, state)`：主路径查映射 setbufline 摘要行追加 ` ✓`/` ✗`/`（待审查）`；映射缺失时兜底按 `▸ TOOL` + title 最后一次匹配（title 可能重复，取末次——审查顺序与渲染顺序一致的合理近似）。入队时打"（待审查）"初始标记（时序：render.Update 先渲染、diff.OnToolEvent 后入队打标——tasks 1.2 定序）。

### D6：配置与命令

- `g:agent_shell_diff_auto`（默认 0）：completed + 有窗口（bufwinnr）时自动 Review
- `g:agent_shell_diff_chain`（默认 0）：审查完自动下一 pending
- 命令：`:AgentDiffReview [n]`（无参=首个 pending）、`:AgentDiffAccept`、`:AgentDiffReject`、`:AgentDiffNext`、`:AgentDiffStatus`
- 聊天 buffer 折叠块映射补 `d`（转发 Review 该块条目；README 标注 `d` 覆盖 normal 删除 operator，有 y/n 先例）

### D7：mock 夹具扩展（B4：mock 落盘模拟真实 agent）

prompt 含 "edit" 时 mock 发完整六事件序列（对齐 wire 契约小节的形状：pending tool_call → locations update → 参数 update → **diff content update** → completed），**且 python 侧同步将 newText 写入目标文件**（模拟 agent 已落盘——真实行为）。目标文件固定 `/tmp/agent_shell_edit_test.txt`（测试前置写入基准内容）。

## Risks / Trade-offs

- [tool_call_update 事件形状与 claude 适配器不同（pi/geohar 桥）] → 解析只依赖 ACP 标准字段（content[].type='diff'、locations、status）；适配器 _meta 扩展不依赖；pi 桥形状在 M2 验收冒烟中实测，偏差记档
- [多 tab 干扰] → 审查 tab 命名固定；Teardown 必回原 tab
- [拒绝写回大文件] → writefile 直写；失败 catch 警告（不做原子性主张）
- [headless 无法测 vimdiff 视觉] → 场景拆分：捕获/接受/拒绝/队列/标记走命令路径断言（Review 在 headless 返回 false 后纯命令驱动 active_idx）；视图/映射/回跳归手动清单
- [「拒绝后 agent 上下文失真」] → spec R3 已言明 + 聊天提示行（D4）；README 工作流章节说明改后审的固有语义

## Migration Plan

纯增量。M1 遗留修复（tool_call_update 渲染）随本变更交付，22 断言回归护住。回滚 revert 即可。

## Open Questions

无。
