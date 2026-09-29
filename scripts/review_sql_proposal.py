"""Review and decide a proposed deanery SQL change from the terminal."""

import argparse
import json
import sys
from pathlib import Path

import httpx


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from dean_agent.config import settings


def main() -> None:
    parser = argparse.ArgumentParser(description="Проверить предложение SQL-изменения")
    parser.add_argument("proposal_id")
    parser.add_argument("--actor", required=True, help="Логин сотрудника в deanery.app_user")
    parser.add_argument("--url", default="http://127.0.0.1:8080")
    args = parser.parse_args()
    if not settings.deanery_approval_token:
        raise SystemExit("В .env не задан DEANERY_APPROVAL_TOKEN")
    headers = {"X-Actor-ID": args.actor, "X-Approval-Token": settings.deanery_approval_token}
    endpoint = f"{args.url.rstrip('/')}/sql-proposals/{args.proposal_id}"
    with httpx.Client(timeout=30, trust_env=False) as client:
        response = client.get(endpoint, headers=headers)
        response.raise_for_status()
        proposal = response.json()
        print(f"Статус: {proposal['status']}")
        print(f"Кто предложил: {proposal['created_by']}")
        print(f"Действие: {proposal['explanation']}")
        print(f"Причина: {proposal['reason']}")
        print("Проверенный эффект:")
        print(json.dumps(proposal["preview"], ensure_ascii=False, indent=2))
        print(f"SQL: {proposal['sql']}")
        if proposal["status"] != "pending":
            return
        choice = input("Решение [approve/reject/cancel]: ").strip().lower()
        if choice == "cancel" or choice not in {"approve", "reject"}:
            return
        reason = input("Причина решения (обязательно): ").strip()
        if len(reason) < 10:
            raise SystemExit("Причина должна содержать не меньше 10 символов")
        response = client.post(endpoint + "/decision", headers=headers,
                               json={"approve": choice == "approve", "reason": reason})
        response.raise_for_status()
        print(f"Результат: {response.json()['status']}")


if __name__ == "__main__":
    main()
