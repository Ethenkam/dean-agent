-- =====================================================================
--  Автотесты правил целостности, расписания, аудита и прав доступа
--  Выполнять после 01–05 (от postgres). Все изменения откатываются.
--  Каждый тест печатает «✓ …»; если правило не сработало — скрипт
--  останавливается с ошибкой «✗ …».
-- =====================================================================
SET search_path TO deanery, public;
SET client_min_messages TO notice;
BEGIN;

-- Ожидаем ошибку: выполняем команды и проверяем, что база их отвергла
CREATE FUNCTION pg_temp.expect_error(p_what TEXT, VARIADIC p_sql TEXT[]) RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE q TEXT;
BEGIN
    BEGIN
        FOREACH q IN ARRAY p_sql LOOP EXECUTE q; END LOOP;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE '✓ %  →  %', p_what, SQLERRM;
        RETURN;
    END;
    RAISE EXCEPTION '✗ Правило не сработало: %', p_what;
END $$;

-- Ожидаем успех; последняя команда — проверка, возвращающая TRUE.
-- Изменения откатываются, роль возвращается.
CREATE FUNCTION pg_temp.expect_ok(p_what TEXT, VARIADIC p_sql TEXT[]) RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE i INT; ok BOOLEAN;
BEGIN
    BEGIN
        FOR i IN 1 .. array_length(p_sql, 1) - 1 LOOP EXECUTE p_sql[i]; END LOOP;
        EXECUTE p_sql[array_length(p_sql, 1)] INTO ok;
        IF ok IS NOT TRUE THEN
            RAISE EXCEPTION USING ERRCODE = 'P0098', MESSAGE = 'проверка вернула ' || COALESCE(ok::TEXT, 'NULL');
        END IF;
        RAISE EXCEPTION USING ERRCODE = 'P0099';          -- откат всего, что сделали
    EXCEPTION
        WHEN SQLSTATE 'P0099' THEN RAISE NOTICE '✓ %', p_what; RETURN;
        WHEN OTHERS THEN RAISE EXCEPTION '✗ %  →  %', p_what, SQLERRM;
    END;
END $$;

\echo '== Согласованность между таблицами =='
SELECT pg_temp.expect_error('Оценка студенту не из группы ведомости',
    'INSERT INTO grade (sheet_id, student_id, points) VALUES (9, 1, 30)');
SELECT pg_temp.expect_error('Ведомость по дисциплине чужого учебного плана',
    $q$INSERT INTO grade_sheet (sheet_number, item_id, group_id, examiner_id, issue_date) VALUES ('T-1', 1, 2, 6, CURRENT_DATE)$q$);
SELECT pg_temp.expect_error('Учебное поручение по дисциплине чужого плана',
    'INSERT INTO teaching_assignment (item_id, group_id, teacher_id, lesson_type_id) VALUES (9, 1, 8, 1)');
SELECT pg_temp.expect_error('Посещаемость студенту из другой группы',
    $q$INSERT INTO attendance (slot_id, student_id, lesson_date, is_present) VALUES (1, 6, '2026-09-28', TRUE)$q$);
SELECT pg_temp.expect_error('Посещаемость в день, когда занятия нет',
    $q$INSERT INTO attendance (slot_id, student_id, lesson_date, is_present) VALUES (1, 1, '2026-09-29', TRUE)$q$);
SELECT pg_temp.expect_error('Посещаемость по чётной неделе для занятия по нечётным',
    $q$INSERT INTO attendance (slot_id, student_id, lesson_date, is_present) VALUES (3, 1, '2026-09-09', TRUE)$q$);
SELECT pg_temp.expect_error('Посещаемость студенту в академическом отпуске',
    $q$INSERT INTO attendance (slot_id, student_id, lesson_date, is_present) VALUES (4, 10, '2026-09-08', TRUE)$q$);
SELECT pg_temp.expect_error('Староста из другой группы',
    $q$UPDATE study_group SET headman_id = 6 WHERE name = 'ПИ-23'$q$);
SELECT pg_temp.expect_ok('Старосту снимает с должности перевод в другую группу',
    $q$CALL sp_transfer_student(1, 'ПИ-24', 'T-TR', 1)$q$,
    $q$SELECT headman_id IS NULL FROM study_group WHERE name = 'ПИ-23'$q$);
SELECT pg_temp.expect_error('Заведующий кафедрой не с этой кафедры',
    'SET CONSTRAINTS ALL IMMEDIATE',
    $q$UPDATE department SET head_id = 8 WHERE short_name = 'ИС'$q$);
SELECT pg_temp.expect_error('Перевод заведующего на другую кафедру',
    'SET CONSTRAINTS ALL IMMEDIATE',
    'UPDATE teacher SET department_id = 2 WHERE employee_id = 5');
SELECT pg_temp.expect_error('Директор института на преподавательской должности',
    'UPDATE institute SET director_id = 6 WHERE institute_id = 1');
SELECT pg_temp.expect_error('Преподаватель на административной должности',
    'INSERT INTO teacher (employee_id, department_id) VALUES (2, 1)');
SELECT pg_temp.expect_error('Преподаватель одновременно в деканате',
    'INSERT INTO dean_office_staff (employee_id, institute_id) VALUES (6, 1)');
SELECT pg_temp.expect_error('Смена должности преподавателя на методиста',
    'UPDATE employee SET position_id = 4 WHERE employee_id = 6');
SELECT pg_temp.expect_error('Практика по строке плана, которая не практика',
    $q$INSERT INTO practice_placement (student_id, item_id, supervisor_id, org_contact_id, start_date, end_date)
       VALUES (6, 7, 6, 1, '2026-07-01', '2026-07-20')$q$);
SELECT pg_temp.expect_error('Практика из чужого учебного плана',
    $q$INSERT INTO practice_placement (student_id, item_id, supervisor_id, org_contact_id, start_date, end_date)
       VALUES (6, 15, 6, 1, '2026-07-01', '2026-07-20')$q$);
SELECT pg_temp.expect_error('Тема курсовой к экзаменационной дисциплине',
    $q$INSERT INTO academic_work (student_id, item_id, topic, supervisor_id) VALUES (1, 3, 'Тема', 6)$q$);
SELECT pg_temp.expect_error('Пересекающиеся академические отпуска',
    $q$INSERT INTO academic_leave (student_id, reason_id, order_id, start_date, end_date)
       VALUES (10, 1, 4, '2026-06-01', '2026-12-01')$q$);
SELECT pg_temp.expect_error('Академический отпуск дольше 2 лет',
    $q$INSERT INTO academic_leave (student_id, reason_id, order_id, start_date, end_date)
       VALUES (10, 1, 4, '2028-01-01', '2030-06-01')$q$);
SELECT pg_temp.expect_error('Академический отпуск по приказу о зачислении',
    $q$INSERT INTO academic_leave (student_id, reason_id, order_id, start_date, end_date)
       VALUES (1, 1, 1, '2027-01-01', '2027-06-01')$q$);
SELECT pg_temp.expect_error('Та же стипендия на пересекающийся период',
    $q$INSERT INTO scholarship (student_id, scholarship_type_id, order_id, start_date, end_date)
       VALUES (1, 2, 6, '2026-10-01', '2026-12-31')$q$);
SELECT pg_temp.expect_error('Баллы ниже минимума шкалы (24)',
    'INSERT INTO grade (sheet_id, student_id, points) VALUES (9, 9, 24)');
SELECT pg_temp.expect_error('Баллы выше максимума шкалы (55)',
    'INSERT INTO grade (sheet_id, student_id, points) VALUES (9, 9, 55)');
SELECT pg_temp.expect_error('Баллы и неявка одновременно',
    'INSERT INTO grade (sheet_id, student_id, points, is_absent) VALUES (9, 9, 30, TRUE)');
SELECT pg_temp.expect_error('Модульная ведомость по практике (у практики модулей нет)',
    $q$INSERT INTO grade_sheet (sheet_number, item_id, group_id, examiner_id, stage, issue_date) VALUES ('X-M', 15, 1, 7, 'module_1', CURRENT_DATE)$q$);
SELECT pg_temp.expect_error('Вторая основная ведомость на модуль 1',
    $q$INSERT INTO grade_sheet (sheet_number, item_id, group_id, examiner_id, stage, issue_date) VALUES ('X-M2', 1, 1, 6, 'module_1', CURRENT_DATE)$q$);
SELECT pg_temp.expect_error('Пересечение диапазонов шкалы (34 → и «3», и «4»)',
    'UPDATE score_band SET max_points = 36 WHERE mark = 3');
SELECT pg_temp.expect_error('Исправление оценки в закрытой ведомости',
    'UPDATE grade SET points = 30 WHERE sheet_id = 1 AND student_id = 1');

\echo '== Расписание =='
SELECT pg_temp.expect_error('Аудитория занята другим преподавателем',
    $q$INSERT INTO schedule_slot (assignment_id, classroom_id, weekday, pair_number, term_id)
       VALUES (9, 1, 1, 1, 2)$q$);
SELECT pg_temp.expect_error('Преподаватель уже ведёт занятие в это время',
    $q$INSERT INTO schedule_slot (assignment_id, classroom_id, weekday, pair_number, term_id)
       VALUES (12, 3, 3, 1, 2)$q$);
SELECT pg_temp.expect_error('У группы уже есть пара в это время',
    $q$INSERT INTO schedule_slot (assignment_id, classroom_id, weekday, pair_number, term_id)
       VALUES (10, 2, 2, 1, 2)$q$);
SELECT pg_temp.expect_error('В аудитории не хватает мест',
    'UPDATE classroom SET capacity = 3 WHERE classroom_id = 3',
    $q$INSERT INTO schedule_slot (assignment_id, classroom_id, weekday, pair_number, term_id)
       VALUES (3, 3, 5, 4, 2)$q$);
SELECT pg_temp.expect_error('Замена преподавателя в поручении создаёт ему накладку',
    $q$INSERT INTO schedule_slot (assignment_id, classroom_id, weekday, pair_number, term_id)
       VALUES (16, 3, 1, 1, 2)$q$,
    'UPDATE teaching_assignment SET teacher_id = 5 WHERE assignment_id = 16');
SELECT pg_temp.expect_ok('Нечётная и чётная неделя в одной аудитории не конфликтуют',
    $q$INSERT INTO schedule_slot (assignment_id, classroom_id, weekday, pair_number, week_parity, term_id)
       VALUES (13, 1, 3, 3, 'even', 2)$q$,
    'SELECT TRUE');
SELECT pg_temp.expect_ok('Лекционный поток: одна лекция для двух групп в одной аудитории',
    $q$INSERT INTO schedule_slot (assignment_id, classroom_id, weekday, pair_number, term_id)
       VALUES (1, 1, 2, 1, 2)$q$,
    'SELECT TRUE');

\echo '== Журнал изменений =='
SELECT pg_temp.expect_ok('Изменение записывается с пользователем и запросом агента',
    $q$SET LOCAL app.user_id = '2'$q$,
    $q$SET LOCAL app.agent_request_id = '1'$q$,
    $q$UPDATE person SET phone = '+7 999 000-00-00' WHERE person_id = 14$q$,
    $q$SELECT EXISTS (SELECT 1 FROM v_audit WHERE table_name = 'person' AND record_key = 'person_id=14'
                      AND changed_by = 'kuznetsova' AND column_name = 'phone'
                      AND new_value = '+7 999 000-00-00' AND agent_request IS NOT NULL)$q$);
SELECT pg_temp.expect_ok('Паспортные данные в журнале скрыты',
    $q$UPDATE person SET passport_number = '999999' WHERE person_id = 14$q$,
    $q$SELECT bool_and(old_value = '***' AND new_value = '***') FROM audit_log_detail WHERE column_name = 'passport_number'$q$);
SELECT pg_temp.expect_ok('Изменение без реальных отличий не засоряет журнал',
    'UPDATE student SET status_id = status_id WHERE student_id = 2',
    $q$SELECT NOT EXISTS (SELECT 1 FROM audit_log WHERE table_name = 'student' AND record_key = 'student_id=2')$q$);
SELECT pg_temp.expect_error('Журнал нельзя исправить',
    $q$UPDATE person SET phone = '+7 999 000-00-01' WHERE person_id = 15$q$,
    $q$UPDATE audit_log SET db_user = 'кто-то другой'$q$);
SELECT pg_temp.expect_error('Из журнала нельзя удалить запись',
    $q$UPDATE person SET phone = '+7 999 000-00-01' WHERE person_id = 15$q$,
    'DELETE FROM audit_log');

\echo '== Права доступа: агент =='
SELECT pg_temp.expect_ok('Агент читает представления',
    'SET LOCAL ROLE deanery_agent',
    $q$SELECT count(*) > 0 FROM v_students$q$);
SELECT pg_temp.expect_error('Агент не видит паспортные данные',
    'SET LOCAL ROLE deanery_agent', 'SELECT passport_number FROM person');
SELECT pg_temp.expect_error('Агент не видит хэши паролей',
    'SET LOCAL ROLE deanery_agent', 'SELECT password_hash FROM app_user');
SELECT pg_temp.expect_error('Агент не может удалять данные',
    'SET LOCAL ROLE deanery_agent', 'DELETE FROM document_request');
SELECT pg_temp.expect_error('Агент не может менять справочники',
    'SET LOCAL ROLE deanery_agent', $q$UPDATE score_band SET min_points = 20 WHERE mark = 3$q$);
SELECT pg_temp.expect_error('Агент не может менять учётные записи',
    'SET LOCAL ROLE deanery_agent', 'UPDATE app_user SET role_id = 1');
SELECT pg_temp.expect_error('Агент не может менять паспорт студента',
    'SET LOCAL ROLE deanery_agent', $q$UPDATE person SET passport_number = '000000' WHERE person_id = 14$q$);
SELECT pg_temp.expect_error('Агент не читает журнал напрямую',
    'SET LOCAL ROLE deanery_agent', 'SELECT * FROM audit_log_detail');
SELECT pg_temp.expect_ok('Агент зачисляет студента процедурой',
    'SET LOCAL ROLE deanery_agent',
    $q$SELECT fn_enroll_student('Тестов','Тест',NULL,'M','2008-01-01','test@stud.univ.ru',NULL,
                                'ПМИ-25','Бюджет','25-9999','T-ENR',CURRENT_DATE,1)$q$,
    $q$SELECT EXISTS (SELECT 1 FROM v_students WHERE record_book_number = '25-9999')$q$);
SELECT pg_temp.expect_ok('Агент оформляет академический отпуск; изменения попадают в журнал',
    'SET LOCAL ROLE deanery_agent',
    $q$CALL sp_grant_academic_leave(4, 'Семейные обстоятельства', '2026-10-01', '2027-06-30', 'T-LV', 1)$q$,
    $q$SELECT EXISTS (SELECT 1 FROM v_academic_leaves WHERE student LIKE 'Егорова%' AND reason = 'Семейные обстоятельства')
          AND EXISTS (SELECT 1 FROM v_audit WHERE table_name = 'academic_leave')$q$);
SELECT pg_temp.expect_ok('Агент переводит старосту (право на снятие старосты есть)',
    'SET LOCAL ROLE deanery_agent',
    $q$CALL sp_transfer_student(7, 'ПИ-23', 'T-TR2', 1)$q$,
    $q$SELECT headman_id IS NULL FROM study_group WHERE name = 'ПИ-24'$q$);

\echo '== Права доступа: другие роли =='
SELECT pg_temp.expect_ok('Преподаватель ставит оценку',
    'SET LOCAL ROLE deanery_teacher',
    'INSERT INTO grade (sheet_id, student_id, points) VALUES (9, 9, 30)',
    'SELECT TRUE');
SELECT pg_temp.expect_error('Преподаватель не меняет данные студентов',
    'SET LOCAL ROLE deanery_teacher', 'UPDATE student SET funding_type_id = 1');
SELECT pg_temp.expect_error('Роль «только чтение» ничего не меняет',
    'SET LOCAL ROLE deanery_read',
    $q$INSERT INTO document_request (student_id, document_type_id, request_status_id) VALUES (1, 1, 1)$q$);
SELECT pg_temp.expect_ok('Деканат видит журнал изменений',
    'SET LOCAL ROLE deanery_staff',
    'SELECT count(*) >= 0 FROM audit_log');

\echo '== Защита от неверного ввода =='
SELECT pg_temp.expect_error('Пустая фамилия',
    $q$INSERT INTO person (last_name, first_name, gender, birth_date) VALUES ('', 'Иван', 'M', '2000-01-01')$q$);
SELECT pg_temp.expect_error('Фамилия из одних пробелов',
    $q$INSERT INTO person (last_name, first_name, gender, birth_date) VALUES ('   ', 'Иван', 'M', '2000-01-01')$q$);
SELECT pg_temp.expect_error('Пробелы по краям названия группы',
    $q$UPDATE study_group SET name = ' ПИ-23' WHERE group_id = 1$q$);
SELECT pg_temp.expect_error('Дата рождения в будущем',
    $q$INSERT INTO person (last_name, first_name, gender, birth_date) VALUES ('Тест', 'Иван', 'M', '2030-01-01')$q$);
SELECT pg_temp.expect_error('Email, отличающийся от существующего только регистром',
    $q$INSERT INTO person (last_name, first_name, gender, birth_date, email) VALUES ('Тест', 'Иван', 'M', '2000-01-01', 'IVANOV.KS@stud.univ.ru')$q$);
SELECT pg_temp.expect_error('Логин, отличающийся от существующего только регистром',
    $q$INSERT INTO app_user (person_id, role_id, login, password_hash) VALUES (15, 5, 'Smirnov', 'x')$q$);
SELECT pg_temp.expect_error('Дата зачисления раньше рождения',
    $q$UPDATE student SET enrollment_date = '1990-01-01' WHERE student_id = 1$q$);
SELECT pg_temp.expect_error('Дата приёма на работу раньше рождения',
    $q$UPDATE employee SET hire_date = '1950-01-01' WHERE employee_id = 10$q$);
SELECT pg_temp.expect_error('Семестр 12 в четырёхлетнем плане',
    $q$INSERT INTO curriculum_item (curriculum_id, discipline_id, semester, control_type_id, self_study_hours) VALUES (1, 4, 12, 1, 36)$q$);
SELECT pg_temp.expect_error('Строка плана без единого часа',
    $q$INSERT INTO curriculum_item (curriculum_id, discipline_id, semester, control_type_id) VALUES (1, 4, 5, 1)$q$);
SELECT pg_temp.expect_error('Зачисление с опечаткой в основе обучения',
    $q$SELECT fn_enroll_student('Тест','Тест',NULL,'M','2007-01-01',NULL,NULL,'ПИ-23','Бюджетт','X-9','X-9',CURRENT_DATE,1)$q$);

\echo '== Операции не в том состоянии =='
SELECT pg_temp.expect_error('Повторное отчисление отчисленного',
    $q$CALL sp_expel_student(15, 'X-1', 'повторно', 1)$q$);
SELECT pg_temp.expect_error('Перевод в ту же группу',
    $q$CALL sp_transfer_student(2, 'ПИ-23', 'X-2', 1)$q$);
SELECT pg_temp.expect_error('Перевод отчисленного',
    $q$CALL sp_transfer_student(15, 'ПИ-23', 'X-3', 1)$q$);
SELECT pg_temp.expect_error('Академический отпуск отчисленному',
    $q$CALL sp_grant_academic_leave(15, 'Медицинские показания', '2026-10-01', '2027-01-01', 'X-4', 1)$q$);
SELECT pg_temp.expect_error('Выход из академа у того, кто в нём не был',
    $q$CALL sp_return_from_leave(2, 'X-5', 1)$q$);
SELECT pg_temp.expect_error('Восстановление того, кто не отчислен',
    $q$CALL sp_reinstate_student(2, 'ПИ-23', 'X-6', 1)$q$);
SELECT pg_temp.expect_error('Перевод в архивную группу',
    $q$INSERT INTO curriculum (program_id, study_form_id, start_year, duration_years) VALUES (1, 1, 2019, 4)$q$,
    $q$INSERT INTO study_group (name, curriculum_id, is_archived) VALUES ('ПИ-19', (SELECT MAX(curriculum_id) FROM curriculum), TRUE)$q$,
    $q$CALL sp_transfer_student(2, 'ПИ-19', 'X-7', 1)$q$);
SELECT pg_temp.expect_error('Приказ подписал ассистент',
    'UPDATE academic_order SET signed_by_id = 10 WHERE order_id = 1');
SELECT pg_temp.expect_error('Оценка студенту в академическом отпуске',
    'INSERT INTO grade (sheet_id, student_id, points) VALUES (9, 10, 30)');
SELECT pg_temp.expect_error('Пересдача студенту, который уже сдал',
    'INSERT INTO grade (sheet_id, student_id, points) VALUES (9, 6, 30)');
SELECT pg_temp.expect_error('Вторая основная ведомость на ту же дисциплину',
    $q$INSERT INTO grade_sheet (sheet_number, item_id, group_id, examiner_id, issue_date) VALUES ('X-8', 1, 1, 6, CURRENT_DATE)$q$);
SELECT pg_temp.expect_error('Повторное открытие закрытой ведомости',
    $q$UPDATE grade_sheet SET status = 'open', closed_date = NULL WHERE sheet_id = 1$q$);
SELECT pg_temp.expect_error('Отмена закрытой ведомости',
    $q$UPDATE grade_sheet SET status = 'cancelled', closed_date = NULL WHERE sheet_id = 1$q$);
SELECT pg_temp.expect_error('Закрытие пустой ведомости пересдачи',
    'UPDATE grade_sheet SET status = $$closed$$, closed_date = exam_date WHERE sheet_id = 9');
SELECT pg_temp.expect_error('Закрытие основной ведомости, где оценки есть не у всех',
    $q$INSERT INTO grade_sheet (sheet_number, item_id, group_id, examiner_id, issue_date, exam_date)
       VALUES ('X-9', 3, 1, 5, '2026-09-01', '2026-09-20')$q$,
    $q$INSERT INTO grade (sheet_id, student_id, points) VALUES ((SELECT sheet_id FROM grade_sheet WHERE sheet_number = 'X-9'), 1, 50)$q$,
    $q$UPDATE grade_sheet SET status = 'closed', closed_date = '2026-09-22' WHERE sheet_number = 'X-9'$q$);
SELECT pg_temp.expect_error('Посещаемость на будущую дату',
    $q$INSERT INTO attendance (slot_id, student_id, lesson_date, is_present) VALUES (1, 1, CURRENT_DATE + 7, TRUE)$q$);
SELECT pg_temp.expect_error('Учебное поручение уволенному преподавателю',
    'UPDATE employee SET dismissal_date = CURRENT_DATE WHERE employee_id = 9',
    'INSERT INTO teaching_assignment (item_id, group_id, teacher_id, lesson_type_id) VALUES (4, 1, 9, 2)');
SELECT pg_temp.expect_error('Уволенный преподаватель в экзаменаторах',
    'UPDATE employee SET dismissal_date = CURRENT_DATE WHERE employee_id = 9',
    'UPDATE grade_sheet SET examiner_id = 9 WHERE sheet_id = 8');
SELECT pg_temp.expect_error('Увольнение директора института',
    'UPDATE employee SET dismissal_date = CURRENT_DATE WHERE employee_id = 1');
SELECT pg_temp.expect_error('Увольнение заведующего кафедрой',
    'UPDATE employee SET dismissal_date = CURRENT_DATE WHERE employee_id = 12');
SELECT pg_temp.expect_error('Увольнение куратора группы',
    'UPDATE employee SET dismissal_date = CURRENT_DATE WHERE employee_id = 10');
SELECT pg_temp.expect_error('Архивирование группы с обучающимися',
    'UPDATE study_group SET is_archived = TRUE WHERE group_id = 1');
SELECT pg_temp.expect_error('Государственная стипендия договорнику',
    $q$INSERT INTO scholarship (student_id, scholarship_type_id, order_id, start_date, end_date) VALUES (3, 1, 6, '2026-09-01', '2027-01-31')$q$);
SELECT pg_temp.expect_error('Стипендия отчисленному',
    $q$INSERT INTO scholarship (student_id, scholarship_type_id, order_id, start_date, end_date) VALUES (15, 4, 6, '2026-09-01', '2027-01-31')$q$);
SELECT pg_temp.expect_error('Выданную справку вернуть в статус «Новая»',
    'UPDATE document_request SET request_status_id = 1 WHERE request_id = 1');
SELECT pg_temp.expect_error('Удаление студента вместе со всей историей',
    'SET LOCAL ROLE deanery_staff', 'DELETE FROM student WHERE student_id = 1');
SELECT pg_temp.expect_error('Удаление приказа вместе со списком студентов',
    'DELETE FROM academic_order WHERE order_id = 1');
SELECT pg_temp.expect_error('Удаление занятия, по которому есть посещаемость',
    'DELETE FROM schedule_slot WHERE slot_id = 1');

\echo '== Правильные действия проходят =='
SELECT pg_temp.expect_ok('Восстановление отчисленного студента',
    $q$CALL sp_reinstate_student(15, 'ПМИ-25', 'X-10', 1)$q$,
    $q$SELECT status = 'Обучается' FROM v_students WHERE student_id = 15$q$);
SELECT pg_temp.expect_ok('Академ прекращает выплату стипендии',
    $q$CALL sp_grant_academic_leave(13, 'Семейные обстоятельства', '2026-10-01', '2027-06-30', 'X-11', 1)$q$,
    $q$SELECT end_date = '2026-10-01' FROM scholarship WHERE student_id = 13$q$);
SELECT pg_temp.expect_ok('Выход из академа возвращает статус «Обучается»',
    $q$CALL sp_grant_academic_leave(4, 'Семейные обстоятельства', CURRENT_DATE, CURRENT_DATE + 200, 'X-12', 1)$q$,
    $q$CALL sp_return_from_leave(4, 'X-13', 1)$q$,
    $q$SELECT status = 'Обучается' FROM v_students WHERE student_id = 4$q$);
SELECT pg_temp.expect_ok('Переведённого с долгом можно внести в пересдачу старой группы',
    $q$CALL sp_transfer_student(9, 'ПИ-23', 'X-14', 1)$q$,
    'INSERT INTO grade (sheet_id, student_id, points) VALUES (9, 9, 30)',
    'SELECT TRUE');
SELECT pg_temp.expect_ok('Основная ведомость закрывается, когда оценки есть у всех',
    $q$INSERT INTO grade_sheet (sheet_number, item_id, group_id, examiner_id, issue_date, exam_date)
       VALUES ('X-15', 3, 1, 5, '2026-09-01', '2026-09-20')$q$,
    $q$INSERT INTO grade (sheet_id, student_id, points)
       SELECT (SELECT sheet_id FROM grade_sheet WHERE sheet_number = 'X-15'), student_id, 40 FROM student WHERE group_id = 1$q$,
    $q$UPDATE grade_sheet SET status = 'closed', closed_date = '2026-09-22' WHERE sheet_number = 'X-15'$q$,
    'SELECT TRUE');
SELECT pg_temp.expect_ok('Именная стипендия партнёра доступна и договорнику',
    $q$INSERT INTO scholarship (student_id, scholarship_type_id, order_id, start_date, end_date) VALUES (3, 4, 6, '2026-09-01', '2027-01-31')$q$,
    'SELECT TRUE');
SELECT pg_temp.expect_ok('Старые записи уволенного сотрудника остаются, их можно править',
    'UPDATE study_group SET curator_id = 7 WHERE curator_id = 10',
    'UPDATE employee SET dismissal_date = CURRENT_DATE WHERE employee_id = 10',
    'UPDATE teaching_assignment SET subgroup = 1 WHERE assignment_id = 12',
    'SELECT TRUE');

\echo '== Успеваемость и расписание на семестр =='
SELECT pg_temp.expect_ok('Отчёт: у зачётной дисциплины в столбце «Экзамен» прочерк',
    $q$SELECT module_1 = '50' AND module_2 = '49' AND credit = '50' AND exam = '—' FROM v_performance
       WHERE student_id = 1 AND discipline = 'Иностранный язык' AND semester = 6$q$);
SELECT pg_temp.expect_ok('Отчёт: у экзаменационной дисциплины в столбце «Зачёт» прочерк',
    $q$SELECT module_1 = '48' AND module_2 = '51' AND credit = '—' AND exam = '52' AND final_result = 'Отлично'
       FROM v_performance WHERE student_id = 1 AND discipline = 'Базы данных'$q$);
SELECT pg_temp.expect_ok('Отчёт: у практики нет модулей, но есть оценка в баллах',
    $q$SELECT module_1 = '—' AND module_2 = '—' AND credit = '50' AND final_result = 'Отлично'
       FROM v_performance WHERE student_id = 1 AND discipline = 'Производственная практика'$q$);
SELECT pg_temp.expect_ok('Отчёт: после пересдачи показывается последний результат',
    $q$SELECT exam = '28' AND final_result = 'Удовлетворительно' FROM v_performance
       WHERE student_id = 3 AND discipline = 'Базы данных'$q$);
SELECT pg_temp.expect_ok('Отчёт: «н/а» и «неявка»',
    $q$SELECT module_2 = 'н/а' AND exam = 'неявка' FROM v_performance
       WHERE student_id = 5 AND discipline = 'Базы данных'$q$);
SELECT pg_temp.expect_ok('Перевод баллов в оценку: 34 → 3, 35 → 4, 44 → 4, 45 → 5, 54 → 5',
    'SELECT fn_mark(25) = 3 AND fn_mark(34) = 3 AND fn_mark(35) = 4 AND fn_mark(44) = 4 AND fn_mark(45) = 5 AND fn_mark(54) = 5 AND fn_mark(24) IS NULL');
SELECT pg_temp.expect_ok('Календарь: в праздник 4 ноября занятий нет',
    $q$SELECT NOT EXISTS (SELECT 1 FROM v_schedule_calendar WHERE lesson_date = '2026-11-04')$q$);
SELECT pg_temp.expect_ok('Календарь: занятие по нечётным неделям идёт только в нечётные',
    $q$SELECT bool_and(week = 'нечётная') FROM v_schedule_calendar WHERE slot_id = 3$q$);
SELECT pg_temp.expect_ok('Календарь: у заочников занятия только в установочный период',
    $q$SELECT MIN(lesson_date) = '2026-10-03' AND MAX(lesson_date) = '2026-11-07' FROM v_schedule_calendar WHERE group_name = 'ИВТз-25'$q$);
SELECT pg_temp.expect_ok('Сверка часов: расписание покрывает не меньше 85 % плана по каждому занятию',
    'SELECT bool_and(scheduled_hours >= 0.85 * planned_hours) FROM v_schedule_hours');
SELECT pg_temp.expect_error('Занятие за пределами семестра',
    $q$INSERT INTO schedule_slot (assignment_id, classroom_id, weekday, pair_number, term_id, valid_from, valid_to)
       VALUES (3, 3, 5, 4, 2, '2026-08-01', '2026-09-30')$q$);
SELECT pg_temp.expect_error('Посещаемость в праздничный день',
    $q$INSERT INTO holiday (holiday_date, name) VALUES ('2026-09-21', 'Тестовый выходной')$q$,
    $q$INSERT INTO attendance (slot_id, student_id, lesson_date, is_present) VALUES (12, 1, '2026-09-21', TRUE)$q$);

SELECT pg_temp.expect_ok('Отчёт: ещё не выставленные баллы — пустые ячейки, а не «н/а»',
    $q$SELECT module_1 IS NULL AND module_2 IS NULL AND exam IS NULL AND credit = '—' FROM v_performance
       WHERE student_id = 1 AND discipline = 'Машинное обучение'$q$);

SELECT pg_temp.expect_error('Модули у практики в учебном плане',
    'UPDATE curriculum_item SET module_count = 2 WHERE item_id = 15');

\echo '== Все проверки пройдены =='
ROLLBACK;
