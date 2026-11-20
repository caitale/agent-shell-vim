#!/usr/bin/env python3
"""Mock ACP agent — JSON-RPC 2.0 over stdio（换行分隔 JSON）。

实现最小 ACP 面：
  initialize → session/new → session/prompt（流式 session/update）
  并在轮次中途演示 session/request_permission（agent → client 反向请求）。

prompt 含 "edit" 时走 edit 流程（M2 diff 审查夹具，wire 契约对齐
claude-agent-acp 实测六事件序列）：
  tool_call(pending) → tool_call_update(locations) → tool_call_update(rawInput)
  → tool_call_update(content=[{type:'diff',...}]) → tool_call_update(completed)
  且 python 侧同步将 newText 落盘（模拟真实 agent 行为）。

不依赖任何真实 LLM，用于验证 ACP 客户端协议闭环。
"""
import json
import os
import sys
import uuid

EDIT_TARGET = "/tmp/agent_shell_edit_test.txt"
EDIT_OLD = "alpha\nbeta\ngamma\n"
EDIT_NEW = "alpha\nBETA-CHANGED\ngamma\n"


def send(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def notify(method, params):
    send({"jsonrpc": "2.0", "method": method, "params": params})


def respond(rid, result=None, error=None):
    msg = {"jsonrpc": "2.0", "id": rid}
    msg["error" if error is not None else "result"] = error if error is not None else result
    send(msg)


class Agent:
    def __init__(self):
        self.sid = None
        self.uid = 0
        # 挂起的轮次：等待 client 回复权限请求后继续
        self.pending = None  # {"prompt_id":..., "perm_id":..., "text":..., "edit":bool}

    # ---- helpers ----
    def chunk(self, session_update, content=None, **extra):
        """发一条 session/update。真实 wire format（对拍 claude-agent-acp 实测）：
        params.update.sessionUpdate 为判别字段。"""
        self.uid += 1
        upd = {"sessionUpdate": session_update}
        if content is not None:
            upd["content"] = content
        upd.update(extra)
        notify("session/update", {
            "sessionId": self.sid,
            "updateId": f"u{self.uid}",
            "update": upd,
        })

    # ---- 入口 ----
    def handle_line(self, line):
        msg = json.loads(line)
        if "method" not in msg:  # 这是 client 对我方请求的响应
            self.on_client_response(msg)
            return
        method, rid, params = msg.get("method"), msg.get("id"), msg.get("params", {})
        if method == "initialize":
            respond(rid, {
                "protocolVersion": 1,
                "agentInfo": {"name": "mock-agent", "version": "0.1.0"},
                "capabilities": {},
                "authMethods": [],
            })
        elif method == "session/new":
            self.sid = "sess_" + uuid.uuid4().hex[:12]
            # 对齐真实 agent：session/new 响应带 modes（claude-agent-acp 实测有此字段）
            respond(rid, {"sessionId": self.sid, "modes": {}})
        elif method == "session/prompt":
            self.run_turn(rid, params)
        elif method == "session/cancel":
            respond(rid, {})
        elif method == "session/list":
            self.handle_list(rid, params)
        elif method == "session/load":
            self.handle_load(rid, params)
        else:
            respond(rid, error={"code": -32601, "message": f"unknown method: {method}"})

    def run_turn(self, prompt_id, params):
        text = "".join(
            b.get("text", "") for b in params.get("prompt", []) if b.get("type") == "text"
        )
        # 1) 回显用户消息
        self.chunk("user_message_chunk", {"type": "text", "text": text})
        # 2) 计划
        self.chunk("plan", entries=[
            {"content": "解析请求", "status": "completed"},
            {"content": "调用工具（需授权）", "status": "in_progress"},
        ])
        # 3) 反向请求权限：agent → client，阻塞等待回复
        perm_id = 900 + self.uid
        self.pending = {
            "prompt_id": prompt_id, "perm_id": perm_id, "text": text,
            "edit": "edit" in text.lower(),
        }
        send({
            "jsonrpc": "2.0", "id": perm_id,
            "method": "session/request_permission",
            "params": {
                "sessionId": self.sid,
                "options": [
                    {"optionId": "allow_once", "kind": "allow_once", "text": "允许一次"},
                    {"optionId": "reject_once", "kind": "reject_once", "text": "拒绝"},
                ],
            },
        })

    def on_client_response(self, msg):
        if not self.pending or msg.get("id") != self.pending["perm_id"]:
            return
        outcome = (msg.get("result") or {}).get("outcome", {})
        approved = outcome.get("outcome") == "selected" and outcome.get("optionId") == "allow_once"
        p = self.pending
        self.pending = None
        if not approved:
            self.chunk("agent_message_chunk", {"type": "text", "text": "（权限被拒绝，任务中止）"})
            respond(p["prompt_id"], {"stopReason": "refusal"})
            return
        if p["edit"]:
            self.edit_flow()
        else:
            # 4) 模拟工具调用（grep 演示）
            self.chunk("tool_call", toolCallId=f"tc{self.uid}", title="grep",
                       kind="execute", status="pending", content={"type": "text", "text": "grep -rn TODO ."})
            self.chunk("tool_call", toolCallId=f"tc{self.uid}", title="grep",
                       kind="execute", status="completed", content={"type": "text", "text": "3 matches"})
        # 5) 流式回复（多 chunk 演示流式）
        for piece in (f"收到：「{p['text']}」。", "这是一段流式输出，", "由 mock-agent 分三个 chunk 发出。"):
            self.chunk("agent_message_chunk", {"type": "text", "text": piece})
        respond(p["prompt_id"], {"stopReason": "end_turn"})

    # ---- M3 会话管理夹具（契约对齐两桥实测） ----
    def handle_list(self, rid, params):
        mode = os.environ.get("MOCK_SESS_MODE", "")
        if mode == "empty":
            respond(rid, {"sessions": [], "nextCursor": None})
            return
        if mode == "paged":
            # 两页：首页 1 条 + cursor；带 cursor 参数的请求 → 次页 + null
            if params.get("cursor"):
                respond(rid, {"sessions": [self._sess("sess_mock_p2", "第二页会话")], "nextCursor": None})
            else:
                respond(rid, {"sessions": [self._sess("sess_mock_known", "分页第一条")], "nextCursor": "page2"})
            return
        respond(rid, {
            "sessions": [
                self._sess("sess_mock_known", "可恢复的会话"),
                self._sess("sess_mock_expired", "已过期会话"),
            ],
            "nextCursor": None,
        })

    def _sess(self, sid, title):
        return {
            "sessionId": sid,
            "cwd": "/tmp",
            "title": title,
            "updatedAt": "2026-11-20T10:00:00.000Z",
        }

    def handle_load(self, rid, params):
        sid = params.get("sessionId", "")
        if sid == "sess_mock_known":
            self.sid = sid  # N8：夹具 wire 保真（后续 chunk 携带新 sid）
            respond(rid, {"sessionId": sid, "modes": {}})
            self.chunk("agent_message_chunk", {"type": "text", "text": "已恢复 mock 会话"})
        else:
            respond(rid, error={"code": -32602, "message": f"session not found: {sid}"})

    # ---- edit 六事件流（wire 契约对齐 claude-agent-acp 实测，design「wire 契约」） ----
    def edit_flow(self):
        call_id = f"call_{uuid.uuid4().hex[:24]}"
        # 事件 1：tool_call pending（title 无路径——实证）
        self.chunk("tool_call", toolCallId=call_id, name="Edit", title="Edit",
                   kind="edit", status="pending", content=[], locations=[])
        # 事件 2：locations（路径首次出现）
        self.chunk("tool_call_update", toolCallId=call_id,
                   rawInput={"file_path": EDIT_TARGET},
                   title=f"Edit {os.path.basename(EDIT_TARGET)}",
                   locations=[{"path": EDIT_TARGET}])
        # 事件 3：参数补全
        self.chunk("tool_call_update", toolCallId=call_id,
                   rawInput={"file_path": EDIT_TARGET, "new_string": "BETA-CHANGED"})
        self.chunk("tool_call_update", toolCallId=call_id,
                   rawInput={"file_path": EDIT_TARGET, "old_string": "beta", "new_string": "BETA-CHANGED"})
        # 事件 4：结构化 diff（content[].type='diff'）
        self.chunk("tool_call_update", toolCallId=call_id,
                   rawInput={"replace_all": False, "file_path": EDIT_TARGET,
                             "old_string": "beta", "new_string": "BETA-CHANGED"},
                   content=[{"type": "diff", "path": EDIT_TARGET,
                             "oldText": EDIT_OLD, "newText": EDIT_NEW}])
        # 落盘模拟（真实 agent 行为：completed 前文件已写好）
        with open(EDIT_TARGET, "w") as f:
            f.write(EDIT_NEW)
        # 事件 5/6：完成
        self.chunk("tool_call_update", toolCallId=call_id, status="completed",
                   rawOutput=f"The file {EDIT_TARGET} has been updated successfully.")


def main():
    agent = Agent()
    # 启动噪音（测试夹具行为）：空行 + 非 JSON 行各一条，
    # 用于验证客户端的噪音行容错（spec: acp-transport「噪音行容错」）
    sys.stdout.write("\n")
    sys.stdout.write("noise-not-json\n")
    sys.stdout.flush()
    # edit 夹具基准文件（测试断言的盘上初态；测试也可前置覆盖）
    with open(EDIT_TARGET, "w") as f:
        f.write(EDIT_OLD)
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        agent.handle_line(line)


if __name__ == "__main__":
    main()
