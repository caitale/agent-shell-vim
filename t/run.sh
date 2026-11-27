#!/bin/sh
# run.sh — agent-shell headless 测试入口
# 判定以断言结果文件为准（vim -es 的退出码会被脚本内历史错误污染，
# 不可靠——M2 实证），vim 失败码忽略。
cd "$(dirname "$0")/.."   # 仓库根

echo "== agent-shell test (vim: $(vim --version | head -1 | cut -d' ' -f-2)) =="
rm -f /tmp/agent_shell_test_result.txt
vim -Nu NONE -n -es -S t/test_protocol_session.vim -c 'qa!' || true
# M3：MOCK_SESS_MODE 子进程场景（empty/paged 各一个 vim 进程）
for MODE in empty paged; do
  MOCK_SESS_MODE=$MODE vim -Nu NONE -n -es -S t/test_sess_modes.vim -c 'qa!' || true
  cat /tmp/agent_shell_sess_mode_result.txt >> /tmp/agent_shell_test_result.txt 2>/dev/null
done
# M4：usage 降级（used_only）
MOCK_USAGE_MODE=used_only vim -Nu NONE -n -es -S t/test_usage_mode.vim -c 'qa!' || true
cat /tmp/agent_shell_usage_mode_result.txt >> /tmp/agent_shell_test_result.txt 2>/dev/null
MOCK_NO_MODES=1 vim -Nu NONE -n -es -S t/test_no_modes.vim -c 'qa!' || true
cat /tmp/as_no_modes_result.txt >> /tmp/agent_shell_test_result.txt 2>/dev/null
# token 级流式拼接（2026-11-22 pi 真实试用暴露的碎屏 bug 回归）
MOCK_STREAM_MODE=token vim -Nu NONE -n -es -S t/test_stream_mode.vim -c 'qa!' || true
cat /tmp/as_stream_mode_result.txt >> /tmp/agent_shell_test_result.txt 2>/dev/null
# M5 steering：四模式子进程
for SMODE in preset_none new_turn err queued queued_reject; do
  MOCK_STEER=$SMODE vim -Nu NONE -n -es -S t/test_steer_modes.vim -c 'qa!' || true
  cat /tmp/as_steer_mode_result.txt >> /tmp/agent_shell_test_result.txt 2>/dev/null
done
echo "---- results ----"
cat /tmp/agent_shell_test_result.txt
if grep -q FAIL /tmp/agent_shell_test_result.txt; then
  echo "TEST FAILED"
  exit 1
fi
echo "TEST OK"
