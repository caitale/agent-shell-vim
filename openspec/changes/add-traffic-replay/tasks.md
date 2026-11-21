# Tasks: add-traffic-replay

## 1. 回放引擎

- [ ] 1.1 新建 `autoload/agent_shell/replay.vim`：CLIENT_METHODS 白名单 + `Run(file)`（逐行 decode+Dispatch 整体 try/catch → bad；**响应 id+1000 重映射**——B2 语义 id 隔离；返回统计 dict）+ `RunAndReport(file)`（统计行 render.Log，unknown_mid 提示）
- [ ] 1.2 session.vim：`Dispatch` script-local → export（注释标注回放/测试专用入口；内部分派零改动）

## 2. 样本入库

- [ ] 2.1 `t/replay/claude-full.jsonl`：2026-11-21 **重录**完整轮次样本入库（17 行：initialize/new/prompt/回显/chunk/usage_update×3/stopReason——/tmp/replay_claude_full.jsonl 已验 14/3/0 无密钥）；头部 # 注释四行
- [ ] 2.2 `t/replay/pi-queued.jsonl`：摘排队流核心段（**W3 标准：仅 update 流+stopReason 响应，不含 initialize/new 响应**；excerpt 标注）
- [ ] 2.3 `t/replay/README.md`：录制指南（debug 开关 → 场景 → 脱敏检查 → 注释 → 入库）

## 3. 命令与文档

- [ ] 3.1 plugin：`:AgentReplay <file>`（调 replay.RunAndReport）；配置注释补 g:agent_shell_debug 的回放用途说明
- [ ] 3.2 README：测试章节补 traffic 回放一段（夹具与 mock 的互补关系：mock=契约模型、replay=真实事实）

## 4. 测试与收尾

- [ ] 4.1 t/test_protocol_session.vim 组I（**插入点：H4 后、chat dump 前；每条断言行数锚两件套——B3**）：claude 锚点（replayed==14/skipped==3/bad==0/新增区 stopReason+pong+统计行）、usage 标准口径行（回放后 ShowUsage）、pi 排队（Queued message）、registry 不增（B2）、missing file 新增区、bad lines（bad==2 && replayed==1）
- [ ] 4.2 run.sh 全绿两连跑（89→93 断言）
- [ ] 4.3 README 里程碑行更新；tasks 全勾；validate
- [ ] 4.4 verify（三维： Completeness/Correctness/Coherence）→ 处理发现 → archive → push → CI 绿
