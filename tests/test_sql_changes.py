"""Review, approval and database audit for constrained deanery writes."""

from sqlalchemy.orm import Session
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import delete, text

from dean_agent.api import app
from dean_agent.config import settings
from dean_agent.db import engine, SessionLocal
from dean_agent.models import AuditLog, SQLChangeProposal
from dean_agent.sql_changes import ALLOWED, SQLChangeError, decide_sql_change, parse_change, propose_sql_change


@pytest.mark.parametrize("sql", [
    "ALTER TABLE deanery.document_request ADD COLUMN unsafe text",
    "DELETE FROM deanery.document_request WHERE request_id = 1",
    "UPDATE deanery.document_request SET purpose = 'x'",
    "UPDATE deanery.student SET group_id = 2 WHERE student_id = 1",
    "UPDATE deanery.document_request SET purpose = current_user WHERE request_id = 1",
    "UPDATE deanery.document_request SET purpose = 'x' WHERE request_id > 1",
    "INSERT INTO deanery.document_request (student_id) VALUES (1), (2)",
    "INSERT INTO deanery.document_request (student_id) SELECT student_id FROM deanery.student",
])
def test_reject_unreviewable_changes(sql):
    with pytest.raises(SQLChangeError):
        parse_change(sql)


def test_allowed_tables_match_database_role_permissions():
    with engine.connect() as conn:
        for table in ALLOWED:
            perms = conn.execute(text(
                "SELECT has_table_privilege('deanery_agent', :table, 'SELECT'), "
                "has_table_privilege('deanery_agent', :table, 'INSERT'), "
                "has_table_privilege('deanery_agent', :table, 'UPDATE')"),
                {"table": f"deanery.{table}"}).one()
            assert all(perms), table


def test_contact_preview_rolls_back():
    with engine.connect() as conn:
        outer = conn.begin()
        try:
            with Session(bind=conn, join_transaction_mode="create_savepoint", expire_on_commit=False) as db:
                proposal = propose_sql_change(
                    db,
                    sql_text="UPDATE deanery.contact_person SET email = 'preview-only@example.test' WHERE contact_person_id = 1",
                    explanation="Проверить изменение контактного адреса без записи",
                    reason="Проверка нового разрешённого набора таблиц",
                    actor_id="test-agent", agent_run_id="test-contact")
                assert proposal.preview["table"] == "contact_person"
                assert proposal.preview["after"]["email"] == "preview-only@example.test"
                current = conn.exec_driver_sql(
                    "SELECT email FROM deanery.contact_person WHERE contact_person_id = 1").scalar_one()
                assert current == proposal.preview["before"]["email"]
        finally:
            outer.rollback()


def test_preview_approval_audit_and_stale_rejection():
    with engine.connect() as conn:
        outer = conn.begin()
        try:
            with Session(bind=conn, join_transaction_mode="create_savepoint", expire_on_commit=False) as db:
                proposal = propose_sql_change(
                    db, sql_text="UPDATE deanery.document_request SET purpose = 'Проверка процесса' WHERE request_id = 1",
                    explanation="Изменить назначение заявки на тестовую проверку",
                    reason="Проверка подтверждения сотрудником на тестовой базе",
                    actor_id="test-agent", agent_run_id="test-run")
                assert proposal.preview["affected_rows"] == 1
                assert proposal.preview["before"]["purpose"] != proposal.preview["after"]["purpose"]
                unchanged = conn.exec_driver_sql(
                    "SELECT purpose FROM deanery.document_request WHERE request_id = 1").scalar_one()
                assert unchanged == proposal.preview["before"]["purpose"]
            with Session(bind=conn, join_transaction_mode="create_savepoint", expire_on_commit=False) as db:
                approved = decide_sql_change(
                    db, proposal_id=proposal.id, approver="kuznetsova",
                    decision_reason="Согласована тестовая проверка изменения", approve=True)
                assert approved.status == "approved"
                assert approved.preview["applied"]["purpose"] == "Проверка процесса"
                with pytest.raises(SQLChangeError, match="уже обработано"):
                    decide_sql_change(db, proposal_id=proposal.id, approver="kuznetsova",
                                      decision_reason="Повторное подтверждение для проверки", approve=True)
                db.rollback()
            conn.exec_driver_sql("SET LOCAL ROLE deanery_agent")
            audit = conn.exec_driver_sql(
                "SELECT changed_by, old_value, new_value FROM deanery.v_audit "
                "WHERE table_name = 'document_request' AND record_key = 'request_id=1' "
                "AND column_name = 'purpose' ORDER BY audit_id DESC LIMIT 1").one()
            assert audit.changed_by == "kuznetsova"
            assert audit.new_value == "Проверка процесса"
        finally:
            outer.rollback()


def test_api_requires_staff_token_and_reason():
    client = TestClient(app)
    created = client.post("/sql-proposals", headers={"X-Actor-ID": "test-agent"}, json={
        "sql": "UPDATE deanery.document_request SET purpose = 'Тестовый запрос' WHERE request_id = 1",
        "explanation": "Изменить цель заявки для проверки API",
        "reason": "Проверка двухэтапного маршрута подтверждения",
    })
    assert created.status_code == 200, created.text
    proposal_id = created.json()["id"]
    try:
        bad = client.get(f"/sql-proposals/{proposal_id}", headers={
            "X-Actor-ID": "kuznetsova", "X-Approval-Token": "wrong"})
        assert bad.status_code == 403
        headers = {"X-Actor-ID": "kuznetsova", "X-Approval-Token": settings.deanery_approval_token}
        viewed = client.get(f"/sql-proposals/{proposal_id}", headers=headers)
        assert viewed.status_code == 200
        assert viewed.json()["preview"]["affected_rows"] == 1
        decision = client.post(f"/sql-proposals/{proposal_id}/decision", headers=headers,
                               json={"approve": False, "reason": "Отклонено после тестовой проверки"})
        assert decision.status_code == 200
        assert decision.json()["status"] == "rejected"
    finally:
        with SessionLocal.begin() as db:
            db.execute(delete(AuditLog).where(AuditLog.entity_type == "sql_change_proposal",
                                              AuditLog.entity_id == proposal_id))
            db.execute(delete(SQLChangeProposal).where(SQLChangeProposal.id == proposal_id))
