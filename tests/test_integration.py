"""Integration tests against the local PostgreSQL database."""

import uuid

import pytest
from fastapi.testclient import TestClient
from qdrant_client import models as qdrant_models
from sqlalchemy import delete, select

from dean_agent.api import app
from dean_agent.db import SessionLocal
from dean_agent.models import (AuditLog, ChangeProposal, Group, Regulation,
                               RegulationChunk, Student, StudentGroupHistory)
from dean_agent.services import ProposalError, propose_group_change, resolve_proposal
from dean_agent.tools import build_tools
from dean_agent.vector_search import qdrant_client
from dean_agent.config import settings


@pytest.fixture
def student_case():
    suffix = uuid.uuid4().hex[:10]
    with SessionLocal.begin() as db:
        old = Group(code=f"TEST-{suffix}-A")
        new = Group(code=f"TEST-{suffix}-B")
        db.add_all([old, new])
        db.flush()
        student = Student(full_name=f"Проверка {suffix}", group_id=old.id)
        db.add(student)
        db.flush()
        ids = student.id, old.id, new.id
    yield ids
    student_id, old_id, new_id = ids
    with SessionLocal.begin() as db:
        db.execute(delete(AuditLog).where(AuditLog.entity_type == "student",
                                          AuditLog.entity_id == str(student_id)))
        db.execute(delete(StudentGroupHistory).where(StudentGroupHistory.student_id == student_id))
        db.execute(delete(ChangeProposal).where(ChangeProposal.student_id == student_id))
        db.execute(delete(Student).where(Student.id == student_id))
        db.execute(delete(Group).where(Group.id.in_([old_id, new_id])))


def test_tools_proposal_confirmation_and_stale_check(student_case):
    student_id, old_id, new_id = student_case
    tools = {item.name: item for item in build_tools(SessionLocal, "agent-user", "run-test", include_legacy=True)}
    with SessionLocal() as db:
        new_code = db.get(Group, new_id).code
        old_code = db.get(Group, old_id).code
    found = tools["search_students"].invoke({"name": "Проверка", "group_code": old_code})
    assert any(item["student_id"] == student_id for item in found)
    proposed = tools["propose_student_group_change"].invoke(
        {"student_id": student_id, "new_group_code": new_code})
    assert proposed["confirmation_required"] is True
    with SessionLocal() as db:
        assert db.get(Student, student_id).group_id == old_id
        approved = resolve_proposal(db, uuid.UUID(proposed["proposal_id"]), "staff-1", True)
        assert approved.status == "approved"
    with SessionLocal() as db:
        assert db.get(Student, student_id).group_id == new_id
        assert db.scalar(select(AuditLog).where(AuditLog.entity_id == str(student_id))) is not None
        stale = propose_group_change(db, student_id=student_id,
                                     new_group_code=old_code, actor_id="agent-user", agent_run_id="run-2")
    with SessionLocal.begin() as db:
        db.get(Student, student_id).group_id = old_id
    with SessionLocal() as db:
        with pytest.raises(ProposalError, match="изменилась"):
            resolve_proposal(db, stale.id, "staff-1", True)
        db.rollback()


def test_regulation_upload_and_search():
    client = TestClient(app)
    assert client.get("/health").json()["status"] == "ok"
    assert client.get("/health/vector").json()["status"] == "ok"
    suffix = uuid.uuid4().hex[:10]
    response = client.post("/regulations", headers={"X-Actor-ID": "staff-1"},
                           files={"file": (f"rule-{suffix}.txt",
                                           f"Правило {suffix}: повторная аттестация проводится комиссией.".encode(),
                                           "text/plain")})
    assert response.status_code == 200, response.text
    doc_id = response.json()["id"]
    assert response.json()["index_status"] == "ready"
    try:
        status = client.get(f"/regulations/{doc_id}", headers={"X-Actor-ID": "staff-1"})
        assert status.json()["index_status"] == "ready"
        reindex = client.post(f"/regulations/{doc_id}/reindex",
                              headers={"X-Actor-ID": "staff-1"})
        assert reindex.status_code == 200
        tools = {item.name: item for item in build_tools(SessionLocal, "staff-1", "run-test")}
        results = tools["search_regulations"].invoke({"query": "повторная аттестация комиссия"})
        assert any(item["title"] == f"rule-{suffix}.txt" for item in results)
    finally:
        with SessionLocal() as db:
            chunk_ids = db.scalars(select(RegulationChunk.id).where(
                RegulationChunk.regulation_id == doc_id)).all()
        client = qdrant_client()
        try:
            client.delete(collection_name=settings.qdrant_collection,
                          points_selector=qdrant_models.PointIdsList(points=chunk_ids), wait=True)
        finally:
            client.close()
        with SessionLocal.begin() as db:
            db.execute(delete(AuditLog).where(AuditLog.entity_type == "regulation",
                                              AuditLog.entity_id == str(doc_id)))
            db.execute(delete(Regulation).where(Regulation.id == doc_id))
