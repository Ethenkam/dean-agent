"""The streaming route exposes progress and finishes with the normal response."""

import json

from fastapi.testclient import TestClient

from dean_agent.api import app


def test_sse_events(monkeypatch):
    def fake_agent(message, actor_id, session_id, trace_callback):
        trace_callback("status", {"phase": "model", "message": "Ожидаю ответ модели"})
        trace_callback("tool_call", {"name": "query_deanery", "input": "SELECT ..."})
        trace_callback("tool_result", {"output": "1 row"})
        return {"run_id": "run", "session_id": "session", "answer": "Готово",
                "tools_used": ["query_deanery"], "proposals": []}

    monkeypatch.setattr("dean_agent.api.ask_agent", fake_agent)
    response = TestClient(app).post("/chat/stream", headers={"X-Actor-ID": "test"},
                                    json={"message": "Проверь"})
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/event-stream")
    pairs = []
    for block in response.text.strip().split("\n\n"):
        event, data = block.split("\n", 1)
        pairs.append((event[7:], json.loads(data[6:])))
    assert [name for name, _ in pairs] == ["status", "tool_call", "tool_result", "done"]
    assert pairs[-1][1]["answer"] == "Готово"
