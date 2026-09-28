from sqlalchemy import case, func, select
from sqlalchemy.orm import Session, sessionmaker
from langchain_core.tools import tool

from dean_agent.models import Attendance, Discipline, Grade, Group, Student
from dean_agent.services import ProposalError, propose_group_change
from dean_agent.vector_search import search_regulations_hybrid


def build_tools(session_factory: sessionmaker[Session], actor_id: str, run_id: str):
    @tool
    def search_students(name: str = "", group_code: str = "") -> list[dict]:
        """Find students by part of full name and/or exact group code. At least one filter is required."""
        if not name.strip() and not group_code.strip():
            return [{"error": "Укажите имя или группу"}]
        with session_factory() as db:
            query = select(Student, Group.code).join(Group, Student.group_id == Group.id)
            if name.strip():
                query = query.where(Student.full_name.ilike(f"%{name.strip()}%"))
            if group_code.strip():
                query = query.where(Group.code == group_code.strip())
            rows = db.execute(query.order_by(Student.full_name).limit(30)).all()
            return [{"student_id": s.id, "full_name": s.full_name, "group": code} for s, code in rows]

    @tool
    def get_student_profile(student_id: int) -> dict:
        """Get a student's name and current group by numeric student ID."""
        with session_factory() as db:
            student = db.get(Student, student_id)
            if student is None:
                return {"error": "Студент не найден"}
            return {"student_id": student.id, "full_name": student.full_name, "group": student.group.code}

    @tool
    def get_grades(student_id: int) -> list[dict]:
        """Get grades and debt statuses. grade_recorded_at is entry date, not proven debt formation date."""
        with session_factory() as db:
            rows = db.execute(select(Grade, Discipline.name).join(Discipline).where(Grade.student_id == student_id).order_by(Grade.recorded_at.desc()).limit(100)).all()
            return [{"discipline": name, "grade": grade.value, "status": grade.status,
                     "grade_recorded_at": grade.recorded_at.isoformat()} for grade, name in rows]

    @tool
    def get_academic_debts(student_id: int) -> list[dict]:
        """Get recorded academic debts. grade_recorded_at does not establish when a debt arose."""
        with session_factory() as db:
            rows = db.execute(select(Discipline.name, Grade.recorded_at).join(Grade, Grade.discipline_id == Discipline.id).where(Grade.student_id == student_id, Grade.status == "debt").limit(100)).all()
            return [{"discipline": name, "grade_recorded_at": day.isoformat()} for name, day in rows]

    @tool
    def get_attendance(student_id: int) -> dict:
        """Get counts of recorded attendance rows. Missing rows do not mean absence or full attendance."""
        with session_factory() as db:
            rows = db.execute(select(Discipline.name, func.count(Attendance.id), func.sum(case((Attendance.present.is_(True), 1), else_=0))).join(Attendance, Attendance.discipline_id == Discipline.id).where(Attendance.student_id == student_id).group_by(Discipline.name)).all()
            return {name: {"recorded_lessons": total, "present": present or 0} for name, total, present in rows}

    @tool
    def get_group_statistics(group_code: str, min_debts: int = 0) -> list[dict]:
        """List students in an exact group with debt counts; optionally require at least min_debts."""
        if min_debts < 0 or min_debts > 100:
            return [{"error": "min_debts должен быть от 0 до 100"}]
        with session_factory() as db:
            debt_count = func.count(Grade.id).filter(Grade.status == "debt")
            rows = db.execute(select(Student.id, Student.full_name, debt_count.label("debts"))
                .join(Group, Group.id == Student.group_id)
                .outerjoin(Grade, Grade.student_id == Student.id)
                .where(Group.code == group_code)
                .group_by(Student.id, Student.full_name)
                .having(debt_count >= min_debts)
                .order_by(debt_count.desc(), Student.full_name)
                .limit(100)).all()
            return [{"student_id": sid, "full_name": name, "debts": debts} for sid, name, debts in rows]

    @tool
    def search_regulations(query: str) -> list[dict]:
        """Hybrid semantic search of uploaded regulations using BGE-M3 dense+sparse and Qdrant RRF. Cite title, source and page."""
        if len(query.strip()) < 3:
            return [{"error": "Слишком короткий запрос"}]
        with session_factory() as db:
            try:
                return search_regulations_hybrid(query[:300], db)
            except Exception as exc:
                return [{"error": f"Семантический поиск недоступен ({type(exc).__name__})"}]

    @tool
    def propose_student_group_change(student_id: int, new_group_code: str) -> dict:
        """Create a pending proposal to move a student to another group. Does not change the student; staff must confirm it separately."""
        with session_factory() as db:
            try:
                proposal = propose_group_change(db, student_id=student_id, new_group_code=new_group_code, actor_id=actor_id, agent_run_id=run_id)
            except ProposalError as exc:
                return {"error": str(exc)}
            return {"proposal_id": str(proposal.id), "confirmation_required": True, "old": proposal.old_value, "new": proposal.new_value}

    return [search_students, get_student_profile, get_grades, get_academic_debts,
            get_attendance, get_group_statistics, search_regulations, propose_student_group_change]
