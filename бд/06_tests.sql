-- Проверки большого сида. Запуск от владельца БД с ON_ERROR_STOP=1.
-- Записи подбираются по смыслу, а не по номерам старого демо.
-- Все изменения откатываются; значения последовательностей могут увеличиться.
SET search_path TO deanery, public;
BEGIN;
CREATE FUNCTION pg_temp.assert_true(label TEXT, ok BOOLEAN) RETURNS VOID
LANGUAGE plpgsql AS $$ BEGIN
 IF ok IS DISTINCT FROM TRUE THEN RAISE EXCEPTION '✗ %', label; END IF;
 RAISE NOTICE '✓ %', label;
END $$;
CREATE FUNCTION pg_temp.expect_error(label TEXT, expected_state TEXT, pattern TEXT,
                                    VARIADIC commands TEXT[]) RETURNS VOID
LANGUAGE plpgsql AS $$ DECLARE q TEXT; BEGIN
 BEGIN
  FOREACH q IN ARRAY commands LOOP EXECUTE q; END LOOP;
 EXCEPTION WHEN OTHERS THEN
  IF SQLSTATE <> expected_state OR SQLERRM !~* pattern THEN
   RAISE EXCEPTION '✗ %: ожидалось % / %, получено % / %', label, expected_state, pattern, SQLSTATE, SQLERRM;
  END IF;
  RAISE NOTICE '✓ %', label; RETURN;
 END;
 RAISE EXCEPTION '✗ %: операция неожиданно разрешена', label;
END $$;
CREATE FUNCTION pg_temp.expect_ok(label TEXT, VARIADIC commands TEXT[]) RETURNS VOID
LANGUAGE plpgsql AS $$ DECLARE i INT; ok BOOLEAN; BEGIN
 BEGIN
  FOR i IN 1..array_length(commands,1)-1 LOOP EXECUTE commands[i]; END LOOP;
  EXECUTE commands[array_length(commands,1)] INTO ok;
  IF ok IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'проверка вернула %', ok; END IF;
  RAISE EXCEPTION USING ERRCODE='P0099';
 EXCEPTION WHEN SQLSTATE 'P0099' THEN RAISE NOTICE '✓ %', label; RETURN;
 END;
END $$;

SELECT pg_temp.assert_true('508 студентов и 22 группы',
 (SELECT count(*)=508 FROM student) AND (SELECT count(*)=22 FROM study_group));
SELECT pg_temp.assert_true('Статусы: 494 обучаются, 3 в отпуске, 11 отчислены',
 (SELECT count(*) FILTER(WHERE status_id=1)=494 AND count(*) FILTER(WHERE status_id=2)=3
 AND count(*) FILTER(WHERE status_id=3)=11 FROM student));
SELECT pg_temp.assert_true('История: 1451 ведомость, 25670 результатов, 28 приказов',
 (SELECT count(*)=1451 FROM grade_sheet) AND (SELECT count(*)=25670 FROM grade)
 AND (SELECT count(*)=28 FROM academic_order));
SELECT pg_temp.assert_true('Расписание и посещаемость: 223 занятия, 17480 отметок',
 (SELECT count(*)=223 FROM schedule_slot) AND (SELECT count(*)=17480 FROM attendance));
SELECT pg_temp.assert_true('Есть задолженности, пересдачи, практики, темы и стипендии',
 EXISTS(SELECT FROM v_debtors) AND EXISTS(SELECT FROM grade_sheet WHERE status='open' AND sheet_kind='retake')
 AND EXISTS(SELECT FROM practice_placement) AND EXISTS(SELECT FROM academic_work)
 AND EXISTS(SELECT FROM scholarship));
SELECT pg_temp.assert_true('Шифры групп согласованы с институтом, формой, уровнем и годом',
 NOT EXISTS(SELECT FROM study_group g JOIN curriculum c USING(curriculum_id)
 JOIN study_form sf USING(study_form_id) JOIN study_program pr USING(program_id)
 JOIN specialty sp USING(specialty_id) JOIN education_level el USING(level_id)
 JOIN department d USING(department_id) JOIN institute i USING(institute_id)
 WHERE g.name !~ '^[А-ЯЁ]{3}-[0-9]{2}-[0-9]{2}(\([А-ЯЁ]+\))?$'
 OR left(g.name,6) <> i.group_letter || sf.group_letter || el.group_letter || '-' || right(c.start_year::TEXT,2)));
SELECT pg_temp.assert_true('Баллы в пределах шкалы',
 NOT EXISTS(SELECT FROM grade WHERE points IS NOT NULL AND fn_mark(points) IS NULL));
SELECT pg_temp.assert_true('Посещаемость соответствует календарю и не из будущего',
 NOT EXISTS(SELECT FROM attendance a LEFT JOIN v_schedule_calendar c
 ON c.slot_id=a.slot_id AND c.lesson_date=a.lesson_date
 WHERE c.slot_id IS NULL OR a.lesson_date>CURRENT_DATE));
SELECT pg_temp.assert_true('Старосты обучаются в своих группах',
 NOT EXISTS(SELECT FROM study_group g JOIN student s ON s.student_id=g.headman_id
 JOIN student_status st USING(status_id) WHERE s.group_id<>g.group_id OR NOT st.is_active));
SELECT pg_temp.assert_true('Все триггеры аудита включены',
 EXISTS(SELECT FROM pg_trigger WHERE tgname='audit') AND
 NOT EXISTS(SELECT FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
 JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='deanery' AND t.tgname='audit' AND t.tgenabled<>'O'));

DO $$ DECLARE
 sh RECORD; s INT; other_s INT; inactive_s INT; passed_s INT; head RECORD; target_group TEXT;
 slot RECORD; aid INT; pid INT; req INT; person_id_test INT; teacher_id_test INT; wrong_item INT;
BEGIN
 SELECT * INTO STRICT sh FROM grade_sheet WHERE status='open' AND sheet_kind='retake' ORDER BY sheet_id LIMIT 1;
 SELECT student_id INTO STRICT s FROM student WHERE group_id=sh.group_id AND status_id=1 ORDER BY student_id LIMIT 1;
 SELECT student_id INTO STRICT other_s FROM student WHERE group_id<>sh.group_id AND status_id=1
 AND NOT EXISTS(SELECT FROM grade gr JOIN grade_sheet gs USING(sheet_id)
 WHERE gr.student_id=student.student_id AND gs.item_id=sh.item_id) ORDER BY student_id LIMIT 1;
 SELECT student_id INTO STRICT inactive_s FROM student WHERE status_id=2 ORDER BY student_id LIMIT 1;
 SELECT gr.student_id INTO STRICT passed_s FROM grade gr JOIN grade_sheet gs USING(sheet_id)
 JOIN student st ON st.student_id=gr.student_id
 WHERE gs.item_id=sh.item_id AND gs.stage=sh.stage AND gr.points IS NOT NULL AND st.status_id=1
 AND st.group_id=sh.group_id LIMIT 1;
 PERFORM pg_temp.expect_error('Баллы ниже шкалы','P0001','вне шкалы',format('INSERT INTO grade(sheet_id,student_id,points) VALUES(%s,%s,24)',sh.sheet_id,s));
 PERFORM pg_temp.expect_error('Баллы выше шкалы','P0001','вне шкалы',format('INSERT INTO grade(sheet_id,student_id,points) VALUES(%s,%s,55)',sh.sheet_id,s));
 PERFORM pg_temp.expect_error('Студент чужой группы','P0001','не из группы',format('INSERT INTO grade(sheet_id,student_id,points) VALUES(%s,%s,30)',sh.sheet_id,other_s));
 PERFORM pg_temp.expect_error('Оценка студенту в отпуске','P0001','не обучается',format('INSERT INTO grade(sheet_id,student_id,points) VALUES(%s,%s,30)',sh.sheet_id,inactive_s));
 PERFORM pg_temp.expect_error('Пересдача уже сданного этапа','P0001','уже аттестован',format('INSERT INTO grade(sheet_id,student_id,points) VALUES(%s,%s,30)',sh.sheet_id,passed_s));
 PERFORM pg_temp.expect_error('Нельзя закрыть пустую пересдачу','P0001','пустую ведомость',format('UPDATE grade_sheet SET status=''closed'',closed_date=exam_date WHERE sheet_id=%s',sh.sheet_id));
 SELECT gs.sheet_id,gr.student_id INTO STRICT sh FROM grade_sheet gs JOIN grade gr USING(sheet_id) WHERE status='closed' LIMIT 1;
 PERFORM pg_temp.expect_error('Закрытые результаты неизменяемы','P0001','закрыта или отменена',format('UPDATE grade SET points=30 WHERE sheet_id=%s AND student_id=%s',sh.sheet_id,sh.student_id));
 PERFORM pg_temp.expect_error('Закрытую ведомость нельзя открыть','P0001','изменить её статус нельзя',format('UPDATE grade_sheet SET status=''open'',closed_date=NULL WHERE sheet_id=%s',sh.sheet_id));
 SELECT g.group_id, g.headman_id, g.name INTO STRICT head FROM study_group g WHERE headman_id IS NOT NULL LIMIT 1;
 SELECT name INTO STRICT target_group FROM study_group WHERE group_id<>head.group_id AND NOT is_archived ORDER BY group_id LIMIT 1;
 PERFORM pg_temp.expect_error('Староста чужой группы','P0001','Старостой',format('UPDATE study_group SET headman_id=%s WHERE name=%L',head.headman_id,target_group));
 PERFORM pg_temp.expect_ok('Перевод старосты снимает его с должности',format('CALL sp_transfer_student(%s,%L,''TEST-TRANSFER'',1)',head.headman_id,target_group),format('SELECT headman_id IS NULL FROM study_group WHERE group_id=%s',head.group_id));
 PERFORM pg_temp.expect_error('Архивирование действующей группы','P0001','обучающиеся студенты',format('UPDATE study_group SET is_archived=TRUE WHERE group_id=%s',head.group_id));
 SELECT sl.*,a.group_id INTO STRICT slot FROM schedule_slot sl JOIN teaching_assignment a USING(assignment_id) ORDER BY slot_id LIMIT 1;
 SELECT student_id INTO STRICT s FROM student WHERE group_id=slot.group_id AND status_id=1 ORDER BY student_id LIMIT 1;
 PERFORM pg_temp.expect_error('Посещаемость в будущем','P0001','будущую дату',format('INSERT INTO attendance(slot_id,student_id,lesson_date,is_present) VALUES(%s,%s,CURRENT_DATE+7,TRUE)',slot.slot_id,s));
 PERFORM pg_temp.expect_error('Расписание за пределами семестра','P0001','выходит за даты',format('UPDATE schedule_slot SET valid_from=''2020-01-01'' WHERE slot_id=%s',slot.slot_id));
 PERFORM pg_temp.expect_error('Дублирование занятия группы','P0001','Конфликт расписания',format('INSERT INTO schedule_slot(assignment_id,classroom_id,weekday,pair_number,week_parity,term_id,valid_from,valid_to) SELECT assignment_id,classroom_id,weekday,pair_number,week_parity,term_id,valid_from,valid_to FROM schedule_slot WHERE slot_id=%s',slot.slot_id));
 SELECT employee_id INTO STRICT teacher_id_test FROM teacher ORDER BY employee_id LIMIT 1;
 PERFORM pg_temp.expect_error('Преподаватель на административной должности','P0001','преподаватель',format('UPDATE employee SET position_id=1 WHERE employee_id=%s',teacher_id_test));
 PERFORM pg_temp.expect_error('Нельзя уволить директора','P0001','директор института','UPDATE employee SET dismissal_date=CURRENT_DATE WHERE employee_id=1');
 PERFORM pg_temp.expect_error('Пересечение шкалы','23P01','score_band_no_overlap','UPDATE score_band SET max_points=36 WHERE mark=3');
 PERFORM pg_temp.expect_error('Пустое ФИО','23514','check','INSERT INTO person(last_name,first_name,gender,birth_date) VALUES('''',''Тест'',''M'',''2000-01-01'')');
 PERFORM pg_temp.expect_error('Дата рождения в будущем','P0001','Дата рождения','INSERT INTO person(last_name,first_name,gender,birth_date) VALUES(''Тест'',''Тест'',''M'',CURRENT_DATE+1)');
 SELECT request_id INTO STRICT req FROM document_request r JOIN request_status st USING(request_status_id) WHERE st.is_final ORDER BY request_id LIMIT 1;
 PERFORM pg_temp.expect_error('Завершённую заявку нельзя возобновить','P0001','уже завершена',format('UPDATE document_request SET request_status_id=1 WHERE request_id=%s',req));
 SELECT person_id INTO STRICT person_id_test FROM student WHERE student_id=s;
 PERFORM pg_temp.expect_ok('Изменения записываются с автором',
 'SET LOCAL app.user_id=''2''', 'SET LOCAL app.agent_request_id=''1''',
 format('UPDATE person SET phone=''+7 999 000-00-00'' WHERE person_id=%s',person_id_test),
 format('SELECT EXISTS(SELECT FROM v_audit WHERE record_key=%L AND table_name=''person'' AND column_name=''phone'' AND changed_by=''kuznetsova'' AND agent_request IS NOT NULL)', 'person_id='||person_id_test));
 PERFORM pg_temp.expect_ok('Паспорт скрыт в аудите',
 format('UPDATE person SET passport_number=''999999'' WHERE person_id=%s',person_id_test),
 format('SELECT EXISTS(SELECT FROM audit_log a JOIN audit_log_detail d USING(audit_id) WHERE a.record_key=%L AND d.column_name=''passport_number'' AND d.old_value=''***'' AND d.new_value=''***'')','person_id='||person_id_test));
 PERFORM pg_temp.expect_ok('Обновление без изменений не создаёт аудит',
 format('UPDATE student SET status_id=status_id WHERE student_id=%s',s),
 format('SELECT NOT EXISTS(SELECT FROM audit_log WHERE table_name=''student'' AND record_key=%L)','student_id='||s));
 PERFORM pg_temp.expect_error('Аудит нельзя исправить','P0001','только для чтения',
 format('UPDATE person SET phone=''+7 999 000-00-01'' WHERE person_id=%s',person_id_test), 'UPDATE audit_log SET db_user=''test''');
 PERFORM pg_temp.expect_error('Аудит нельзя удалить','P0001','только для чтения',
 format('UPDATE person SET phone=''+7 999 000-00-01'' WHERE person_id=%s',person_id_test), 'DELETE FROM audit_log');
 PERFORM pg_temp.expect_ok('Агент зачисляет через процедуру','SET LOCAL ROLE deanery_agent',
 format('SELECT fn_enroll_student(''Тестов'',''Тест'',NULL,''M'',''2008-01-01'',''seed-test@example.test'',NULL,%L,''Бюджет'',''TEST-9999'',''TEST-ENROLL'',CURRENT_DATE,1)',head.name),
 'SELECT EXISTS(SELECT FROM v_students WHERE record_book_number=''TEST-9999'')');
END $$;

-- Дополнительные операции: успешные сценарии и отказы по статусу/плану.
DO $$ DECLARE active_s INT; leave_s INT; expelled_s INT; contract_s INT;
 group_name_test TEXT; group_id_test INT; item_test INT; wrong_item INT;
 sheet_test INT; debtor_test INT; email_test TEXT; leave_test RECORD; sch_test RECORD;
BEGIN
 SELECT student_id,group_id INTO STRICT active_s,group_id_test FROM student WHERE status_id=1 ORDER BY student_id LIMIT 1;
 SELECT name INTO STRICT group_name_test FROM study_group WHERE group_id=group_id_test;
 SELECT student_id INTO STRICT leave_s FROM student WHERE status_id=2 ORDER BY student_id LIMIT 1;
 SELECT student_id INTO STRICT expelled_s FROM student WHERE status_id=3 ORDER BY student_id LIMIT 1;
 SELECT student_id INTO STRICT contract_s FROM student WHERE status_id=1 AND funding_type_id=2 ORDER BY student_id LIMIT 1;
 PERFORM pg_temp.expect_error('Перевод в ту же группу','P0001','уже учится',format('CALL sp_transfer_student(%s,%L,''TEST-SAME'',1)',active_s,group_name_test));
 PERFORM pg_temp.expect_error('Перевод отчисленного','P0001','в статусе',format('CALL sp_transfer_student(%s,%L,''TEST-EXPELLED'',1)',expelled_s,group_name_test));
 PERFORM pg_temp.expect_error('Восстановление обучающегося','P0001','в статусе',format('CALL sp_reinstate_student(%s,%L,''TEST-ACTIVE'',1)',active_s,group_name_test));
 PERFORM pg_temp.expect_error('Отпуск студенту в отпуске','P0001','в статусе',format('CALL sp_grant_academic_leave(%s,''Семейные обстоятельства'',CURRENT_DATE,CURRENT_DATE+100,''TEST-DOUBLE'',1)',leave_s));
 PERFORM pg_temp.expect_ok('Агент оформляет отпуск','SET LOCAL ROLE deanery_agent',
 format('CALL sp_grant_academic_leave(%s,''Семейные обстоятельства'',CURRENT_DATE,CURRENT_DATE+100,''TEST-LEAVE'',1)',active_s),
 format('SELECT status=''Академический отпуск'' FROM v_students WHERE student_id=%s',active_s));
 PERFORM pg_temp.expect_ok('Агент восстанавливает студента','SET LOCAL ROLE deanery_agent',
 format('CALL sp_reinstate_student(%s,%L,''TEST-REINSTATE'',1)',expelled_s,group_name_test),
 format('SELECT status=''Обучается'' FROM v_students WHERE student_id=%s',expelled_s));
 PERFORM pg_temp.expect_error('Стипендия договорнику','P0001','по договору',
 format('INSERT INTO scholarship(student_id,scholarship_type_id,start_date,end_date) VALUES(%s,1,CURRENT_DATE,CURRENT_DATE+100)',contract_s));
 PERFORM pg_temp.expect_error('Стипендия в академическом отпуске','P0001','не обучается',
 format('INSERT INTO scholarship(student_id,scholarship_type_id,start_date,end_date) VALUES(%s,4,CURRENT_DATE,CURRENT_DATE+100)',leave_s));
 SELECT * INTO STRICT sch_test FROM scholarship ORDER BY scholarship_id LIMIT 1;
 PERFORM pg_temp.expect_error('Пересечение стипендий','23P01','scholarship',
 format('INSERT INTO scholarship(student_id,scholarship_type_id,order_id,start_date,end_date) VALUES(%s,%s,%s,%L,%L)',sch_test.student_id,sch_test.scholarship_type_id,sch_test.order_id,sch_test.start_date,sch_test.end_date));
 SELECT * INTO STRICT leave_test FROM academic_leave WHERE student_id=leave_s LIMIT 1;
 PERFORM pg_temp.expect_error('Отпуск более двух лет','23514','check',
 format('INSERT INTO academic_leave(student_id,reason_id,order_id,start_date,end_date) VALUES(%s,%s,%s,''2030-01-01'',''2033-01-01'')',leave_s,leave_test.reason_id,leave_test.order_id));
 SELECT ci.item_id INTO STRICT item_test FROM curriculum_item ci JOIN study_group g USING(curriculum_id) JOIN discipline d USING(discipline_id)
 WHERE g.group_id=group_id_test AND d.kind='discipline' ORDER BY item_id LIMIT 1;
 PERFORM pg_temp.expect_error('Практика по обычной дисциплине','P0001','только по строке плана вида',
 format('INSERT INTO practice_placement(student_id,item_id,supervisor_id,org_contact_id,start_date,end_date) VALUES(%s,%s,5,1,CURRENT_DATE,CURRENT_DATE+10)',active_s,item_test));
 PERFORM pg_temp.expect_error('Тема по обычной дисциплине','P0001','Тему можно закрепить',
 format('INSERT INTO academic_work(student_id,item_id,topic,supervisor_id) VALUES(%s,%s,''Тестовая тема'',5)',active_s,item_test));
 SELECT ci.item_id INTO STRICT wrong_item FROM curriculum_item ci WHERE curriculum_id<>(SELECT curriculum_id FROM study_group WHERE group_id=group_id_test) ORDER BY item_id LIMIT 1;
 PERFORM pg_temp.expect_error('Ведомость чужого учебного плана','P0001','не входит в учебный план группы',
 format('INSERT INTO grade_sheet(sheet_number,item_id,group_id,examiner_id,issue_date) VALUES(''TEST-WRONG-PLAN'',%s,%s,5,CURRENT_DATE)',wrong_item,group_id_test));
 SELECT email INTO STRICT email_test FROM person WHERE email IS NOT NULL ORDER BY person_id LIMIT 1;
 PERFORM pg_temp.expect_error('Email уникален без учёта регистра','23505','duplicate key',
 format('INSERT INTO person(last_name,first_name,gender,birth_date,email) VALUES(''Тест'',''Тест'',''M'',''2000-01-01'',%L)',upper(email_test)));
 SELECT gs.sheet_id,lr.student_id INTO STRICT sheet_test,debtor_test FROM grade_sheet gs
 JOIN v_last_result lr ON lr.item_id=gs.item_id AND lr.stage=gs.stage
 JOIN student st ON st.student_id=lr.student_id
 WHERE gs.status='open' AND gs.sheet_kind='retake' AND st.group_id=gs.group_id AND st.status_id=1 AND lr.points IS NULL LIMIT 1;
 PERFORM pg_temp.expect_ok('Преподаватель выставляет результат пересдачи','SET LOCAL ROLE deanery_teacher',
 format('INSERT INTO grade(sheet_id,student_id,points) VALUES(%s,%s,30)',sheet_test,debtor_test),
 format('SELECT points=30 FROM grade WHERE sheet_id=%s AND student_id=%s',sheet_test,debtor_test));
END $$;

SELECT pg_temp.expect_ok('Агент читает представления','SET LOCAL ROLE deanery_agent','SELECT count(*)=508 FROM v_students');
SELECT pg_temp.expect_error('Агент не читает паспорта','42501','permission denied','SET LOCAL ROLE deanery_agent','SELECT passport_number FROM person');
SELECT pg_temp.expect_error('Агент не читает пароли','42501','permission denied','SET LOCAL ROLE deanery_agent','SELECT password_hash FROM app_user');
SELECT pg_temp.expect_error('Агент не удаляет заявки','42501','permission denied','SET LOCAL ROLE deanery_agent','DELETE FROM document_request');
SELECT pg_temp.expect_error('Агент не меняет шкалу','42501','permission denied','SET LOCAL ROLE deanery_agent','UPDATE score_band SET min_points=20 WHERE mark=3');
SELECT pg_temp.expect_error('Агент не читает аудит напрямую','42501','permission denied','SET LOCAL ROLE deanery_agent','SELECT audit_id FROM audit_log_detail');
SELECT pg_temp.expect_error('Чтение не позволяет запись','42501','permission denied','SET LOCAL ROLE deanery_read','INSERT INTO document_request(student_id,document_type_id,request_status_id) VALUES(1,1,1)');
SELECT pg_temp.expect_error('Преподаватель не меняет контингент','42501','permission denied','SET LOCAL ROLE deanery_teacher','UPDATE student SET funding_type_id=1');
SELECT pg_temp.expect_ok('Деканат читает аудит','SET LOCAL ROLE deanery_staff','SELECT count(*)>=0 FROM audit_log');
SELECT pg_temp.assert_true('Праздники исключены из календаря',NOT EXISTS(SELECT FROM v_schedule_calendar c JOIN holiday h ON h.holiday_date=c.lesson_date));
SELECT pg_temp.assert_true('Сводки доступны',EXISTS(SELECT FROM v_performance) AND EXISTS(SELECT FROM v_student_rating) AND EXISTS(SELECT FROM v_groups));
ROLLBACK;
\echo 'Все проверки пройдены'
