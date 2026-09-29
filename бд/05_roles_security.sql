-- =====================================================================
--  Роли и права доступа
--  Выполнять после 01–03 от имени владельца БД с правом CREATEROLE
--  (например, postgres). Скрипт можно запускать повторно.
--
--  deanery_read     — только просмотр: представления и справочники,
--                     без паспортов, СНИЛС, ИНН, адресов и хэшей паролей
--  deanery_teacher  — просмотр + выставление оценок и посещаемости
--  deanery_staff    — сотрудники деканата: полный доступ к рабочим данным
--  deanery_agent    — учётная запись интеллектуального агента (LOGIN):
--                     читает и изменяет рабочие данные, но НИЧЕГО не удаляет,
--                     не видит персональные документы, не меняет справочники,
--                     учётные записи и журнал изменений
-- =====================================================================
SET search_path TO deanery, public;

DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'deanery_read')    THEN CREATE ROLE deanery_read NOLOGIN;    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'deanery_teacher') THEN CREATE ROLE deanery_teacher NOLOGIN; END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'deanery_staff')   THEN CREATE ROLE deanery_staff NOLOGIN;   END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'deanery_agent')   THEN
        -- ОБЯЗАТЕЛЬНО смените пароль:  ALTER ROLE deanery_agent PASSWORD '...';
        CREATE ROLE deanery_agent LOGIN PASSWORD 'change_me_agent' CONNECTION LIMIT 20;
    END IF;
END $$;

GRANT deanery_read TO deanery_teacher, deanery_staff, deanery_agent;

-- ---------- чистый лист: по умолчанию ни у кого нет прав ----------
REVOKE ALL ON ALL TABLES    IN SCHEMA deanery FROM PUBLIC, deanery_read, deanery_teacher, deanery_staff, deanery_agent;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA deanery FROM PUBLIC, deanery_read, deanery_teacher, deanery_staff, deanery_agent;
-- функции в PostgreSQL по умолчанию доступны всем — закрываем
REVOKE EXECUTE ON ALL FUNCTIONS  IN SCHEMA deanery FROM PUBLIC;
REVOKE EXECUTE ON ALL PROCEDURES IN SCHEMA deanery FROM PUBLIC;

DO $$ BEGIN
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO deanery_read', current_database());
END $$;
GRANT USAGE ON SCHEMA deanery TO deanery_read;

-- =====================================================================
-- deanery_read: просмотр
-- =====================================================================
-- все представления, кроме журнала изменений и контактов родителей
DO $$
DECLARE v TEXT;
BEGIN
    FOR v IN SELECT table_name FROM information_schema.views
             WHERE table_schema = 'deanery' AND table_name NOT IN ('v_audit', 'v_student_contacts')
    LOOP
        EXECUTE format('GRANT SELECT ON deanery.%I TO deanery_read', v);
    END LOOP;
END $$;

-- таблицы без персональных документов
GRANT SELECT ON
    position, academic_degree, academic_title, education_level, study_form, funding_type,
    student_status, control_type, score_band, academic_term, holiday, lesson_type, pair_time,
    order_type, scholarship_type, document_type, request_status, app_role, leave_reason,
    contact_relation, institute, department, organization_contact, classroom, employee, teacher, dean_office_staff,
    specialty, study_program, curriculum, discipline, curriculum_item, study_group, student,
    teaching_assignment, schedule_slot, attendance, grade_sheet, grade, academic_order,
    order_student, scholarship, academic_leave, organization, practice_placement, academic_work,
    document_request, agent_intent, agent_request
TO deanery_read;

-- person: только ФИО и контакты, без паспорта, СНИЛС, ИНН, адреса, даты рождения
GRANT SELECT (person_id, last_name, first_name, middle_name, gender, phone, email) ON person TO deanery_read;
-- app_user: без хэша пароля
GRANT SELECT (user_id, person_id, role_id, login, is_active, created_at, last_login_at) ON app_user TO deanery_read;

-- функции, которые используются в представлениях
GRANT EXECUTE ON FUNCTION fn_full_name(person), fn_course(INT, DATE), fn_semester(INT, DATE), fn_credits(curriculum_item),
                          fn_slot_period(schedule_slot), fn_week_number(DATE, DATE), fn_mark(INT),
                          fn_result_name(INT, BOOLEAN, BOOLEAN, BOOLEAN), fn_result_cell(INT, BOOLEAN),
                          fn_group_institute(INT) TO deanery_read;

-- =====================================================================
-- deanery_teacher: оценки и посещаемость
-- (какие ведомости может заполнять конкретный преподаватель — проверяет приложение)
-- =====================================================================
GRANT INSERT, UPDATE ON grade, attendance TO deanery_teacher;

-- =====================================================================
-- deanery_staff: сотрудники деканата
-- =====================================================================
GRANT SELECT, INSERT, UPDATE, DELETE ON
    person, student, contact_person, student_contact, organization_contact, study_group, teaching_assignment, schedule_slot, attendance,
    grade_sheet, grade, academic_order, order_student, scholarship, academic_leave, organization,
    practice_placement, academic_work, document_request, curriculum, curriculum_item, discipline
TO deanery_staff;
-- справочники деканат пополняет, но не удаляет (на них ссылаются данные)
GRANT INSERT, UPDATE ON
    scholarship_type, document_type, request_status, order_type, leave_reason, contact_relation,
    specialty, study_program, classroom, academic_term, holiday
TO deanery_staff;
GRANT SELECT ON audit_log, audit_log_detail, v_audit, v_student_contacts TO deanery_staff;
GRANT EXECUTE ON FUNCTION fn_enroll_student(TEXT, TEXT, TEXT, CHAR, DATE, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, DATE, INT),
                          fn_student_order(INT, TEXT, TEXT, TEXT, INT, TEXT, INT, DATE),
                          fn_require_status(INT, TEXT[], TEXT)
TO deanery_staff;
GRANT EXECUTE ON PROCEDURE sp_expel_student(INT, TEXT, TEXT, INT),
                           sp_transfer_student(INT, TEXT, TEXT, INT),
                           sp_grant_academic_leave(INT, TEXT, DATE, DATE, TEXT, INT),
                           sp_return_from_leave(INT, TEXT, INT),
                           sp_reinstate_student(INT, TEXT, TEXT, INT)
TO deanery_staff;

-- =====================================================================
-- deanery_agent: интеллектуальный агент — принцип минимальных прав
-- =====================================================================
-- добавлять и изменять рабочие данные можно, удалять — нельзя
GRANT INSERT, UPDATE ON
    student, grade_sheet, grade, attendance, schedule_slot, teaching_assignment,
    academic_order, order_student, scholarship, academic_leave, practice_placement,
    academic_work, document_request, contact_person, student_contact, organization_contact, agent_request
TO deanery_agent;
-- найти уже известного родителя (например, брата или сестры), чтобы не заводить дубль
GRANT SELECT ON contact_person, student_contact TO deanery_agent;
-- староста снимается автоматически при переводе — агенту нужно право на эту колонку
GRANT UPDATE (headman_id) ON study_group TO deanery_agent;
-- персоны: создавать при зачислении; менять только ФИО и контакты, но не документы
GRANT INSERT ON person TO deanery_agent;
GRANT UPDATE (last_name, first_name, middle_name, phone, email, address) ON person TO deanery_agent;
-- просмотр истории изменений и контактов родителей (для ответов на вопросы)
GRANT SELECT ON v_audit, v_student_contacts TO deanery_agent;
-- составные операции деканата
GRANT EXECUTE ON FUNCTION fn_enroll_student(TEXT, TEXT, TEXT, CHAR, DATE, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, DATE, INT),
                          fn_student_order(INT, TEXT, TEXT, TEXT, INT, TEXT, INT, DATE),
                          fn_require_status(INT, TEXT[], TEXT)
TO deanery_agent;
GRANT EXECUTE ON PROCEDURE sp_expel_student(INT, TEXT, TEXT, INT),
                           sp_transfer_student(INT, TEXT, TEXT, INT),
                           sp_grant_academic_leave(INT, TEXT, DATE, DATE, TEXT, INT),
                           sp_return_from_leave(INT, TEXT, INT),
                           sp_reinstate_student(INT, TEXT, TEXT, INT)
TO deanery_agent;

-- агент не может выполнять запросы бесконечно
ALTER ROLE deanery_agent SET statement_timeout = '15s';
ALTER ROLE deanery_agent SET search_path = deanery, public;
