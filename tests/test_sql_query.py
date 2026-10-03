"""The SQL tool must use the deanery role and reject broad or writable SQL."""

import pytest
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError

from dean_agent.db import DeaneryReadSession
from dean_agent.sql_query import QueryRejected, execute_read_query, validate_read_query


@pytest.mark.parametrize("sql", [
    "SELECT * FROM v_students LIMIT 5",
    "SELECT s.* FROM v_students s LIMIT 5",
    "SELECT student_id FROM v_students",
    "SELECT student_id FROM v_students LIMIT 61",
    "DELETE FROM student",
    "WITH x AS (DELETE FROM student RETURNING student_id) SELECT student_id FROM x LIMIT 1",
    "SELECT student_id FROM v_students LIMIT 5; SELECT student_id FROM v_students LIMIT 5",
])
def test_reject_unsafe_sql(sql):
    with pytest.raises(QueryRejected):
        validate_read_query(sql)


def test_read_students_with_pagination_and_aggregation():
    with DeaneryReadSession() as db:
        first = execute_read_query(db, "SELECT student_id, full_name FROM v_students ORDER BY student_id LIMIT 2 OFFSET 0")
    with DeaneryReadSession() as db:
        second = execute_read_query(db, "SELECT student_id, full_name FROM v_students ORDER BY student_id LIMIT 2 OFFSET 2")
    with DeaneryReadSession() as db:
        count = execute_read_query(db, "SELECT count(*) AS n FROM v_students LIMIT 1")
    assert len(first["rows"]) == len(second["rows"]) == 2
    assert first["rows"][0]["student_id"] != second["rows"][0]["student_id"]
    assert count["rows"][0]["n"] == 508
    with DeaneryReadSession() as db:
        statuses = execute_read_query(
            db, "SELECT status, count(*) AS n FROM v_students GROUP BY status LIMIT 10")
    assert {row["status"]: row["n"] for row in statuses["rows"]} == {
        "Обучается": 494, "Академический отпуск": 3, "Отчислен": 11,
    }
    with DeaneryReadSession() as db:
        groups = execute_read_query(
            db, "SELECT count(DISTINCT group_name) AS n FROM v_students LIMIT 1")
    assert groups["rows"][0]["n"] == 22


def test_read_role_cannot_switch_to_application_role_or_write():
    with DeaneryReadSession() as db:
        with pytest.raises(DBAPIError):
            db.execute(text("SELECT set_config('role', 'dean_agent', true)"))
        db.rollback()
        with pytest.raises(DBAPIError):
            db.execute(text("UPDATE deanery.student SET group_id = group_id WHERE student_id = -1"))
