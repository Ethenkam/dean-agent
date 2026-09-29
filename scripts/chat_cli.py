"""A small terminal client for the local dean agent."""

import argparse
import json

import httpx


def main() -> None:
    parser = argparse.ArgumentParser(description="Поговорить с агентом деканата")
    parser.add_argument("--actor", default="demo-staff", help="X-Actor-ID для локального прототипа")
    parser.add_argument("--url", default="http://127.0.0.1:8080")
    args = parser.parse_args()
    session_id = None
    print("Агент деканата. /new — новый диалог, /exit — выход.")
    with httpx.Client(timeout=httpx.Timeout(None, connect=5), trust_env=False) as client:
        while True:
            try:
                message = input("Вы: ").strip()
            except (EOFError, KeyboardInterrupt):
                print()
                return
            if message == "/exit":
                return
            if message == "/new":
                session_id = None
                print("Начат новый диалог.")
                continue
            if not message:
                continue
            try:
                with client.stream("POST", f"{args.url.rstrip('/')}/chat/stream",
                                   headers={"X-Actor-ID": args.actor},
                                   json={"message": message, "session_id": session_id}) as response:
                    if response.is_error:
                        raw = response.read().decode(errors="replace")
                        try:
                            detail = json.loads(raw).get("detail", raw)
                        except ValueError:
                            detail = raw
                        print(f"Ошибка API {response.status_code}: {detail}")
                        continue
                    event = None
                    for line in response.iter_lines():
                        if line.startswith("event: "):
                            event = line[7:]
                        elif line.startswith("data: ") and event:
                            data = json.loads(line[6:])
                            if event == "session":
                                session_id = data["session_id"]
                            elif event == "status":
                                print(f"[процесс] {data['message']}" +
                                      (f" ({data['elapsed_s']} с)" if "elapsed_s" in data else ""))
                            elif event == "tool_call":
                                print(f"[вызов {data['name']}] {data['input']}")
                            elif event == "tool_result":
                                print(f"[результат] {data['output']}" +
                                      (" [обрезано]" if data.get("truncated") else ""))
                            elif event == "done":
                                session_id = data["session_id"]
                                print(f"Агент: {data['answer']}")
                                for proposal in data.get("proposals", []):
                                    print(f"Предложение {proposal['id']}: {proposal['preview']}")
                                print(f"[session_id: {session_id}]")
                            elif event == "error":
                                print(f"Ошибка агента ({data['type']}): {data['message']}")
                            event = None
            except (httpx.HTTPError, ValueError) as exc:
                print(f"Ошибка: {exc}")
                continue


if __name__ == "__main__":
    main()
