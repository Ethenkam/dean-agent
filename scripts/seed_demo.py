"""Add clearly synthetic data for a local demo. Safe to run repeatedly."""

from datetime import date

from sqlalchemy import select

from dean_agent.db import SessionLocal
from dean_agent.models import Attendance, Discipline, Grade, Group, Student


def get_or_create(db, model, **lookup):
    item = db.scalar(select(model).filter_by(**lookup))
    if item is None:
        item = model(**lookup)
        db.add(item)
        db.flush()
    return item


def main():
    with SessionLocal.begin() as db:
        first = get_or_create(db, Group, code="ДЕМО-24-01")
        second = get_or_create(db, Group, code="ДЕМО-24-02")
        first.name = "Демонстрационная группа 1"
        second.name = "Демонстрационная группа 2"
        anna = get_or_create(db, Student, full_name="Анна Тестова", group_id=first.id)
        boris = get_or_create(db, Student, full_name="Борис Примеров", group_id=first.id)
        maths = get_or_create(db, Discipline, name="Демо: математика")
        db_course = get_or_create(db, Discipline, name="Демо: базы данных")
        physics = get_or_create(db, Discipline, name="Демо: физика")
        for student, discipline, status, value in [
            (anna, maths, "debt", 2), (anna, db_course, "debt", 2),
            (anna, physics, "debt", 2), (boris, maths, "passed", 4),
        ]:
            if db.scalar(select(Grade).where(Grade.student_id == student.id,
                                             Grade.discipline_id == discipline.id)) is None:
                db.add(Grade(student_id=student.id, discipline_id=discipline.id,
                             status=status, value=value, recorded_at=date(2026, 9, 1)))
        if db.scalar(select(Attendance).where(Attendance.student_id == anna.id)) is None:
            db.add(Attendance(student_id=anna.id, discipline_id=maths.id,
                              lesson_date=date(2026, 9, 2), present=False))
    print("Демонстрационные данные добавлены: ДЕМО-24-01, ДЕМО-24-02")


if __name__ == "__main__":
    main()
