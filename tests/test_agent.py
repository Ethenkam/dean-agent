import json
import threading
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

from dean_agent.agent import ChatSessionError, ask_agent
from dean_agent.config import settings
from dean_agent.db import SessionLocal
from dean_agent.models import ChatSession


def test_deepagent_uses_only_business_tools_and_calls_one(monkeypatch):
    requests = []
    traces = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_POST(self):
            request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            requests.append(request)
            if len(requests) == 1:
                message = {"role": "assistant", "content": None, "tool_calls": [{
                    "id": "test-call", "type": "function",
                    "function": {"name": "query_deanery", "arguments": json.dumps({"sql": "SELECT student_id FROM v_students LIMIT 1"})},
                }]}
                finish = "tool_calls"
            else:
                message = {"role": "assistant", "content": "Студенты не найдены."}
                finish = "stop"
            body = json.dumps({"id": "chatcmpl-test", "object": "chat.completion",
                               "created": 0, "model": "mock",
                               "choices": [{"index": 0, "message": message, "finish_reason": finish}],
                               "usage": {"prompt_tokens": 20, "completion_tokens": 10, "total_tokens": 30}}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = HTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    monkeypatch.setattr(settings, "openai_base_url", f"http://127.0.0.1:{server.server_port}/v1")
    monkeypatch.setattr(settings, "openai_model", "mock")
    try:
        result = ask_agent("Найди студентов", "test-staff",
                           trace_callback=lambda event, data: traces.append((event, data)))
        followup = ask_agent("А сколько их?", "test-staff", uuid.UUID(result["session_id"]))
        with pytest.raises(ChatSessionError):
            ask_agent("Чужой диалог", "another-staff", uuid.UUID(result["session_id"]))
    finally:
        server.shutdown()
        thread.join(timeout=2)
        if "result" in locals():
            with SessionLocal.begin() as db:
                db.delete(db.get(ChatSession, uuid.UUID(result["session_id"])))
    assert result["answer"] == "Студенты не найдены."
    assert len(requests) == 3
    assert followup["session_id"] == result["session_id"]
    assert any(item.get("content") == "Найди студентов" for item in requests[2]["messages"])
    assert any(item.get("content") == "Студенты не найдены." for item in requests[2]["messages"])
    names = {item["function"]["name"] for item in requests[0]["tools"]}
    assert names == {"query_deanery", "propose_sql_change", "search_regulations"}
    assert any(message.get("role") == "tool" for message in requests[1]["messages"])
    assert any(event == "tool_call" and data["name"] == "query_deanery" for event, data in traces)
    assert any(event == "tool_result" for event, _ in traces)
