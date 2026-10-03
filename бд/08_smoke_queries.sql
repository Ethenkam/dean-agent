-- Только чтение: быстрый обзор нового набора.
SET search_path TO deanery, public;
SELECT status, count(*) AS students FROM v_students GROUP BY status ORDER BY status;
SELECT group_name, count(*) AS students FROM v_students GROUP BY group_name ORDER BY group_name;
SELECT student, group_name, discipline, attempts, last_result
FROM v_debtors ORDER BY attempts DESC, student LIMIT 20;
SELECT sheet_number, stage, sheet_kind, exam_date, status
FROM grade_sheet WHERE status='open' ORDER BY exam_date, sheet_number LIMIT 20;
SELECT group_name, lesson_date, pair_number, discipline, teacher, classroom
FROM v_schedule_calendar WHERE group_name='ИДБ-23-11'
AND lesson_date BETWEEN DATE '2026-10-05' AND DATE '2026-10-10'
ORDER BY lesson_date, pair_number;
SELECT * FROM v_attendance_stats LIMIT 10;
