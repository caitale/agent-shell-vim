#!/bin/sh
# run.sh — agent-shell headless 测试入口
# 判定以断言结果文件为准（vim -es 的退出码会被脚本内历史错误污染，
# 不可靠——M2 实证），vim 失败码忽略。
cd "$(dirname "$0")/.."   # 仓库根

echo "== agent-shell test (vim: $(vim --version | head -1 | cut -d' ' -f-2)) =="
rm -f /tmp/agent_shell_test_result.txt
vim -Nu NONE -n -es -S t/test_protocol_session.vim -c 'qa!' || true
echo "---- results ----"
cat /tmp/agent_shell_test_result.txt
if grep -q FAIL /tmp/agent_shell_test_result.txt; then
  echo "TEST FAILED"
  exit 1
fi
echo "TEST OK"
