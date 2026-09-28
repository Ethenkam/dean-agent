import json
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

from dean_agent.agent import ask_agent
from dean_agent.config import settings


def test_deepagent_uses_only_business_tools_and_calls_one(monkeypatch):
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_POST(self):
            request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            requests.append(request)
            if len(requests) == 1:
                message = {"role": "assistant", "content": None, "tool_calls": [{
                    "id": "test-call", "type": "function",
                    "function": {"name": "search_students", "arguments": json.dumps({"group_code": "NO-SUCH-GROUP"})},
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
        result = ask_agent("Найди студентов", "test-staff")
    finally:
        server.shutdown()
        thread.join(timeout=2)
    assert result["answer"] == "Студенты не найдены."
    assert len(requests) == 2
    names = {item["function"]["name"] for item in requests[0]["tools"]}
    assert names == {"search_students", "get_student_profile", "get_grades",
                     "get_academic_debts", "get_attendance", "get_group_statistics",
                     "search_regulations", "propose_student_group_change"}
    assert any(message.get("role") == "tool" for message in requests[1]["messages"])
