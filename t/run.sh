#!/bin/sh
# run.sh — agent-shell headless 测试入口
# 用法：./t/run.sh（在仓库根或任意目录执行均可）
set -e
cd "$(dirname "$0")/.."   # 仓库根

echo "== agent-shell test (vim: $(vim --version | head -1 | cut -d' ' -f-2)) =="
vim -Nu NONE -n -es -S t/test_protocol_session.vim -c 'qa!'
echo "---- results ----"
cat /tmp/agent_shell_test_result.txt
grep -q FAIL /tmp/agent_shell_test_result.txt && { echo "TEST FAILED"; exit 1; }
echo "TEST OK"
