-- =====================================================================
--  Примеры CRUD-операций для основных сущностей деканата
--  Скрипт завёрнут в транзакцию с ROLLBACK — его можно запускать
--  сколько угодно раз, данные не изменятся. Для реальных изменений
--  замените ROLLBACK на COMMIT.
-- =====================================================================
SET search_path TO deanery, public;
BEGIN;

-- =====================================================================
-- СТУДЕНТЫ
-- =====================================================================

-- CREATE: зачисление одной функцией (персона + студент + приказ)
SELECT fn_enroll_student(
    'Андреев', 'Михаил', 'Юрьевич', 'M', '2008-04-12',
    'andreev.my@stud.univ.ru', '+7 915 200-00-21',
    'ПМИ-25', 'Бюджет', '25-0106',
    '1502-с', CURRENT_DATE, 1) AS new_student_id;

-- READ: карточка, список группы, поиск по фамилии
SELECT * FROM v_students WHERE record_book_number = '25-0106';
SELECT full_name, record_book_number, funding, status
FROM v_students WHERE group_name = 'ПИ-23' ORDER BY full_name;
SELECT full_name, group_name FROM v_students WHERE full_name ILIKE 'иван%';

-- UPDATE: смена телефона (персональные данные — в person) и основы обучения
UPDATE person SET phone = '+7 916 555-44-33'
WHERE person_id = (SELECT person_id FROM student WHERE record_book_number = '25-0106');

UPDATE student SET funding_type_id = (SELECT funding_type_id FROM funding_type WHERE name = 'Договор')
WHERE record_book_number = '25-0106';

-- UPDATE (бизнес-операции): перевод и отчисление с приказами
-- (подзапрос в аргументах CALL запрещён, поэтому id берём в DO-блоке)
DO $$
DECLARE v_id INT;
BEGIN
    SELECT student_id INTO v_id FROM student WHERE record_book_number = '25-0106';
    CALL sp_transfer_student(v_id, 'ИВТз-25', '1503-с', 1);
    CALL sp_expel_student(v_id, '1504-с', 'По собственному желанию', 1);
END $$;
-- Напрямую по известному id:  CALL sp_expel_student(15, '1504-с', 'По собственному желанию', 1);
SELECT * FROM v_student_orders WHERE student LIKE 'Андреев%' ORDER BY order_number;

-- DELETE: в деканате студентов не удаляют физически (история приказов и оценок),
-- а переводят в статус «Отчислен». Физическое удаление ошибочно внесённой записи:
DELETE FROM order_student WHERE student_id = (SELECT student_id FROM student WHERE record_book_number = '25-0106');
DELETE FROM student WHERE record_book_number = '25-0106';
DELETE FROM person  WHERE email = 'andreev.my@stud.univ.ru';

-- =====================================================================
-- ПРЕПОДАВАТЕЛИ
-- =====================================================================

-- CREATE: персона → сотрудник → преподаватель
WITH p AS (
    INSERT INTO person (last_name, first_name, middle_name, gender, birth_date, email, phone)
    VALUES ('Жукова', 'Вера', 'Андреевна', 'F', '1991-09-09', 'zhukova.va@univ.ru', '+7 900 111-01-14')
    RETURNING person_id
), e AS (
    INSERT INTO employee (person_id, personnel_number, position_id, employment_rate, hire_date)
    SELECT person_id, 'Т-0014',
           (SELECT position_id FROM position WHERE title = 'Старший преподаватель'),
           1.00, CURRENT_DATE
    FROM p RETURNING employee_id
)
INSERT INTO teacher (employee_id, department_id, degree_id, teaching_since)
SELECT employee_id,
       (SELECT department_id FROM department WHERE short_name = 'ИС'),
       (SELECT degree_id FROM academic_degree WHERE short_name = 'к.т.н.'),
       '2018-09-01'
FROM e;

-- READ
SELECT full_name, position, degree, academic_title, department, teaching_experience_years
FROM v_teachers ORDER BY department, full_name;
SELECT * FROM v_teacher_load ORDER BY total_hours DESC;

-- UPDATE: присвоено звание доцента, ставка 1.25
UPDATE teacher SET title_id = (SELECT title_id FROM academic_title WHERE name = 'Доцент')
WHERE employee_id = (SELECT employee_id FROM employee WHERE personnel_number = 'Т-0014');
UPDATE employee SET employment_rate = 1.25 WHERE personnel_number = 'Т-0014';

-- DELETE (логическое): увольнение — заполняется дата, из v_teachers пропадает
UPDATE employee SET dismissal_date = CURRENT_DATE WHERE personnel_number = 'Т-0014';

-- =====================================================================
-- СОТРУДНИКИ ДЕКАНАТА
-- =====================================================================
WITH p AS (
    INSERT INTO person (last_name, first_name, gender, birth_date, email)
    VALUES ('Тихонова', 'Алина', 'F', '1999-02-02', 'tikhonova.a@univ.ru')
    RETURNING person_id
), e AS (
    INSERT INTO employee (person_id, personnel_number, position_id, hire_date)
    SELECT person_id, 'Т-0015', (SELECT position_id FROM position WHERE title = 'Методист'), CURRENT_DATE
    FROM p RETURNING employee_id
)
INSERT INTO dean_office_staff (employee_id, institute_id, office_room, duties)
SELECT employee_id, 1, 'А-214', 'Военно-учётный стол' FROM e;

SELECT personnel_number, full_name, position, unit FROM v_employees ORDER BY category, full_name;

UPDATE dean_office_staff SET duties = 'Военно-учётный стол, справки для военкомата'
WHERE employee_id = (SELECT employee_id FROM employee WHERE personnel_number = 'Т-0015');

DELETE FROM employee WHERE personnel_number = 'Т-0015';   -- каскадом удалит dean_office_staff

-- =====================================================================
-- ГРУППЫ, УЧЕБНЫЕ ПЛАНЫ, РАСПИСАНИЕ
-- =====================================================================
INSERT INTO curriculum (program_id, study_form_id, start_year, duration_years, approved_date)
VALUES (1, 1, 2026, 4.0, '2026-05-20');

INSERT INTO study_group (name, curriculum_id, curator_id)
VALUES ('ПИ-26',
        (SELECT curriculum_id FROM curriculum WHERE program_id = 1 AND study_form_id = 1 AND start_year = 2026),
        (SELECT employee_id FROM employee WHERE personnel_number = 'Т-0007'));

SELECT * FROM v_groups ORDER BY course, group_name;
SELECT weekday_name, pair_number, start_time, discipline, lesson_type, teacher, classroom, week
FROM v_schedule WHERE group_name = 'ПИ-23' ORDER BY weekday, pair_number;

-- Перенос занятия в другую аудиторию
UPDATE schedule_slot
SET classroom_id = (SELECT classroom_id FROM classroom WHERE building = 'Б' AND room_number = '312')
WHERE slot_id = 7;

UPDATE study_group SET is_archived = TRUE WHERE name = 'ПИ-26';

-- =====================================================================
-- УСПЕВАЕМОСТЬ: ведомости и оценки
-- =====================================================================

-- Ведомость пересдачи и оценка
INSERT INTO grade_sheet (sheet_number, item_id, group_id, examiner_id, sheet_kind, issue_date, exam_date)
VALUES ('ПМИ25-МА-П1', 9, 3, 8, 'retake', CURRENT_DATE, CURRENT_DATE + 7);

INSERT INTO grade (sheet_id, student_id, points)          -- 38 баллов = «хорошо»
SELECT sheet_id, 14, 38 FROM grade_sheet WHERE sheet_number = 'ПМИ25-МА-П1';

-- Долг Киселёвой закрыт — её больше нет в списке должников
SELECT * FROM v_debtors ORDER BY group_name, student;
SELECT * FROM v_grades WHERE student_id = 14 ORDER BY exam_date;

-- Исправление оценки в открытой ведомости
UPDATE grade SET points = 47                               -- 47 баллов = «отлично»
WHERE student_id = 14 AND sheet_id = (SELECT sheet_id FROM grade_sheet WHERE sheet_number = 'ПМИ25-МА-П1');

-- Закрытие ведомости
UPDATE grade_sheet SET status = 'closed', closed_date = CURRENT_DATE WHERE sheet_number = 'ПМИ25-МА-П1';

-- Триггеры защищают данные: изменить оценку в закрытой ведомости нельзя,
-- как и поставить баллы вне шкалы 25–54
DO $$
BEGIN
    BEGIN
        UPDATE grade SET points = 30 WHERE sheet_id = 1 AND student_id = 1;
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Ожидаемая ошибка: %', SQLERRM;
    END;
    BEGIN
        INSERT INTO grade (sheet_id, student_id, points) VALUES (9, 9, 20);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Ожидаемая ошибка: %', SQLERRM;
    END;
END $$;

SELECT * FROM v_student_rating ORDER BY avg_points DESC NULLS LAST;

-- Успеваемость студента: баллы за модули и за зачёт / экзамен
SELECT semester, discipline, module_1, module_2, credit AS "зачёт", exam AS "экзамен", final_result
FROM v_performance WHERE student LIKE 'Иванов%' ORDER BY semester, discipline;

-- Расписание группы на весь семестр по датам и сверка часов с учебным планом
SELECT lesson_date, weekday_name, week, pair_number, start_time, discipline, lesson_type, teacher, classroom
FROM v_schedule_calendar WHERE group_name = 'ПИ-23' AND lesson_date BETWEEN '2026-11-02' AND '2026-11-08'
ORDER BY lesson_date, pair_number;
SELECT * FROM v_schedule_hours WHERE group_name = 'ПИ-23' ORDER BY discipline, lesson_type;

-- =====================================================================
-- ПОСЕЩАЕМОСТЬ
-- =====================================================================
INSERT INTO attendance (slot_id, student_id, lesson_date, is_present)
SELECT 1, student_id, '2026-09-28', TRUE FROM student WHERE group_id = 1 AND status_id = 1;

UPDATE attendance SET is_present = FALSE, absence_reason = 'Справка о болезни'
WHERE slot_id = 1 AND student_id = 3 AND lesson_date = '2026-09-28';

SELECT * FROM v_attendance_stats ORDER BY attendance_pct;

-- =====================================================================
-- СТИПЕНДИИ И ПРИКАЗЫ
-- =====================================================================
SELECT * FROM v_active_scholarships ORDER BY amount DESC;

UPDATE scholarship_type SET amount = amount * 1.10;   -- индексация на 10 %

SELECT ot.name, COUNT(*) AS orders, SUM(cnt) AS students
FROM academic_order o
JOIN order_type ot ON ot.order_type_id = o.order_type_id
JOIN (SELECT order_id, COUNT(*) AS cnt FROM order_student GROUP BY order_id) os USING (order_id)
GROUP BY ot.name ORDER BY orders DESC;

-- =====================================================================
-- СПРАВКИ
-- =====================================================================
INSERT INTO document_request (student_id, document_type_id, request_status_id, copies, purpose)
VALUES (2, 1, 1, 1, 'В банк');

SELECT * FROM v_document_queue ORDER BY due_date;

-- Сотрудник берёт в работу, затем выдаёт (completed_at проставит триггер)
UPDATE document_request SET request_status_id = 2, processed_by_id = 4
WHERE student_id = 2 AND purpose = 'В банк';
UPDATE document_request SET request_status_id = 4
WHERE student_id = 2 AND purpose = 'В банк'
RETURNING request_id, completed_at;

DELETE FROM document_request WHERE request_status_id = 5;   -- чистка отклонённых

-- =====================================================================
-- ЖУРНАЛ АГЕНТА: статистика по намерениям
-- =====================================================================
INSERT INTO agent_request (user_id, request_text, intent_code, status)
VALUES (2, 'Покажи расписание ПИ-24 на четверг', 'show_schedule', 'pending');

UPDATE agent_request SET status = 'success', execution_ms = 140,
       response_text = 'Чт: 2 пара — ТВиМС (лекция), 3 пара — ТВиМС (практика)'
WHERE intent_code = 'show_schedule' AND status = 'pending';

SELECT COALESCE(ai.intent_code, 'не распознано') AS intent, ai.operation, ai.target_table,
       COUNT(*) AS requests, ROUND(AVG(ar.execution_ms)) AS avg_ms,
       COUNT(*) FILTER (WHERE ar.status = 'success') AS ok
FROM agent_request ar
LEFT JOIN agent_intent ai ON ai.intent_code = ar.intent_code
GROUP BY ai.intent_code, ai.operation, ai.target_table ORDER BY requests DESC;

-- =====================================================================
-- АКАДЕМИЧЕСКИЙ ОТПУСК
-- =====================================================================
CALL sp_grant_academic_leave(8, 'Семейные обстоятельства', CURRENT_DATE, CURRENT_DATE + 270, '1510-с', 1);
SELECT * FROM v_academic_leaves ORDER BY start_date;
CALL sp_return_from_leave(8, '1511-с', 1);
SELECT student, state, returned_on FROM v_academic_leaves WHERE student LIKE 'Ковалёва%';

-- =====================================================================
-- ПРАКТИКА, КУРСОВЫЕ, ВКР, КОНТАКТЫ РОДИТЕЛЕЙ
-- =====================================================================
SELECT * FROM v_practice ORDER BY organization, student;
-- должность руководителя от организации меняется в одном месте, у всех его практикантов сразу
UPDATE organization_contact SET job_title = 'Руководитель отдела разработки'
WHERE last_name = 'Мельников';

SELECT student, work_kind, topic, supervisor FROM v_academic_works WHERE work_kind = 'ВКР';
UPDATE academic_work SET topic = 'База данных учёта студенческих олимпиад и конкурсов'
WHERE student_id = 9 AND item_id = 17;

-- новый контакт: сначала контактное лицо, затем связь со студентом
WITH cp AS (
    INSERT INTO contact_person (last_name, first_name, middle_name, phone)
    VALUES ('Киселёва', 'Ирина', 'Олеговна', '+7 916 300-00-08')
    RETURNING contact_person_id
)
INSERT INTO student_contact (student_id, contact_person_id, relation_id, is_emergency)
SELECT 14, contact_person_id, (SELECT relation_id FROM contact_relation WHERE name = 'Мать'), TRUE FROM cp;
SELECT * FROM v_student_contacts WHERE is_emergency ORDER BY group_name, student;

-- =====================================================================
-- ЖУРНАЛ ИЗМЕНЕНИЙ: как агент подписывает свои действия
-- Перед изменениями в транзакции агент передаёт, от чьего имени и по какому
-- запросу он действует; триггер аудита запишет это автоматически.
-- =====================================================================
INSERT INTO agent_request (user_id, request_text, intent_code, status)
VALUES (3, 'Поменяй телефон Петровой Дарье на +7 916 777-66-55', NULL, 'pending');

SELECT set_config('app.user_id', '3', TRUE),
       set_config('app.agent_request_id', (SELECT MAX(agent_request_id)::TEXT FROM agent_request), TRUE);

UPDATE person SET phone = '+7 916 777-66-55'
WHERE person_id = (SELECT person_id FROM student WHERE record_book_number = '23-0102');

SELECT changed_at, table_name, record_key, operation, changed_by, agent_request, column_name, old_value, new_value
FROM v_audit WHERE table_name = 'person' ORDER BY audit_id DESC LIMIT 5;

ROLLBACK;
