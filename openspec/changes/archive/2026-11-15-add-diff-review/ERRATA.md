# ERRATA — add-diff-review 归档后勘误（2026-11-15 verify-after-archive）

追溯验证（三维：Completeness/Correctness/Coherence）判定 PASS with warnings。
以下为已知的文档-实现漂移与后续修正，按验证报告记录：

1. **design D3「headless：tabnew 静默失败」已被实证推翻**：
   `-es` 下 `:tabnew`/`:vsplit` 实际能成功（"静默失败"仅对 `:new` 成立）。
   实现改为 `bufwinnr(chatbuf) == -1` 判定窗口存在性（diff.vim Review 入口）。
   design D3 原文的 tabnew 增量校验保留为防御性二次校验，但不再是 headless 判定依据。

2. **design D5「入队时打待审查初始标记」归档时未实施**：
   验证报告 W-1 指出后已补（diff.vim OnToolEvent 入队路径）。
   连带修复：RenderToolCallUpdate 原正则摘放标记路径全部废除，
   改为 tool_meta 结构化重建（`▸ TOOL {title}: {status}{mark} «as»1`）。

3. **wire 契约六事件 vs mock 实发七事件**：
   mock 将参数补全拆为两条 update（new_string → +old_string），
   比 design 契约更细粒度——对合并逻辑是更强的测试，行为兼容。

4. **验证后补充的测试覆盖**（33→35 断言）：
   `diff_next_headless_safe`（AgentDiffNext 此前零覆盖）、
   `diff_empty_old_not_deleted`（空 oldText 不删除场景）。

5. **已知未自动断言项**（归手动清单）：自动弹出（diff_auto）、
   无窗口不弹、vimdiff 视觉/映射/回跳、「映射不残留」（Teardown nunmap
   代码存在但无断言）。
