#!/usr/bin/env python3
"""Mock ACP agent — JSON-RPC 2.0 over stdio（换行分隔 JSON）。

实现最小 ACP 面：
  initialize → session/new → session/prompt（流式 session/update）
  并在轮次中途演示 session/request_permission（agent → client 反向请求）。

不依赖任何真实 LLM，用于验证 ACP 客户端协议闭环。
"""
import json
import sys
import uuid


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
        self.pending = None  # {"prompt_id":..., "perm_id":..., "stage":...}

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
        self.pending = {"prompt_id": prompt_id, "perm_id": perm_id, "text": text}
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
        # 4) 模拟工具调用
        self.chunk("tool_call", toolCallId=f"tc{self.uid}", title="grep",
                   kind="execute", status="pending", content={"type": "text", "text": "grep -rn TODO ."})
        self.chunk("tool_call", toolCallId=f"tc{self.uid}", title="grep",
                   kind="execute", status="completed", content={"type": "text", "text": "3 matches"})
        # 5) 流式回复（多 chunk 演示流式）
        for piece in (f"收到：「{p['text']}」。", "这是一段流式输出，", "由 mock-agent 分三个 chunk 发出。"):
            self.chunk("agent_message_chunk", {"type": "text", "text": piece})
        respond(p["prompt_id"], {"stopReason": "end_turn"})


def main():
    agent = Agent()
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        agent.handle_line(line)


if __name__ == "__main__":
    main()
