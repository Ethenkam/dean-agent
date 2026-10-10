# Агент деканата

Локальная основа проекта: PostgreSQL 17, Qdrant 1.19.1, FastAPI, DeepAgents и OpenAI-совместимый Chat Completions API. Для документов используется BGE-M3 dense+sparse через существующий сервис на `mlspace`, а локальный Qdrant объединяет результаты по RRF. Агент получает данные только через заранее определённые инструменты. Перевод студента оформляется как предложение; отдельный запрос сотрудника подтверждает его и записывает историю и аудит.

## Запуск

```bash
brew services start postgresql@17
python3 -m venv .venv
.venv/bin/pip install -e '.[dev]'
test -f .env || cp .env.example .env
# Укажите DATABASE_URL и параметры своей модели в .env
.venv/bin/alembic upgrade head
.venv/bin/python scripts/reset_deanery.py  # заменяет deanery синтетическим набором; сохраняет резервную копию
python3 -m venv ~/.local/opt/dean-agent/venv
~/.local/opt/dean-agent/venv/bin/pip install -e .
.venv/bin/python scripts/install_local_services.py
```

На этой машине PostgreSQL и база `dean_agent` уже созданы; рабочий `DATABASE_URL` и параметры модели лежат в локальном `.env` (файл не отслеживается Git). Модель должна поддерживать tool calling и endpoint `/v1/chat/completions`. `OPENAI_BASE_URL` включает `/v1`; `OPENAI_MODEL` — точное имя модели у провайдера.

Qdrant установлен в `~/.local/opt/qdrant/1.19.1/qdrant` и запускается при входе пользователя через LaunchAgent `org.dean-agent.qdrant`. Его данные лежат в `.data/qdrant`, API слушает только `127.0.0.1:6333`. BGE-M3 работает на `mlspace:8231`; LaunchAgent `org.dean-agent.bge-tunnel` даёт локальный SSH-туннель `127.0.0.1:8231`. API агента запускает `org.dean-agent.api` на `127.0.0.1:8080`. Если сервис на удалённой машине остановлен, запустите существующий `/home/jovyan/sbogo/bge-api/start.sh`, затем проверьте `GET /health/vector`.

Для новой машины скачайте бинарник Qdrant перед запуском `install_local_services.py`:

```bash
mkdir -p ~/.local/opt/qdrant/1.19.1
curl -fL https://github.com/qdrant/qdrant/releases/download/v1.19.1/qdrant-aarch64-apple-darwin.tar.gz \
  | tar xz -C ~/.local/opt/qdrant/1.19.1
```

Сервисы после изменения кода можно перезапустить командой `python3 scripts/install_local_services.py`.

Откройте [Swagger UI](http://127.0.0.1:8080/docs). Все операции, кроме `/health`, требуют заголовок `X-Actor-ID` с идентификатором сотрудника.

```bash
curl -s http://127.0.0.1:8080/health
curl -s -X POST http://127.0.0.1:8080/chat \
  -H 'Content-Type: application/json' -H 'X-Actor-ID: demo-staff' \
  -d '{"message":"Какие студенты учатся в ПИ-23?"}'
```

Для разговора в терминале: `.venv/bin/python scripts/chat_cli.py`. Клиент сохраняет `session_id` между репликами; команда `/new` начинает новый диалог. В API передавайте полученный `session_id` в следующем `POST /chat`, чтобы агент видел предыдущие вопросы и ответы этого сотрудника. История хранится в PostgreSQL (последние 20 сообщений передаются модели).

Для живого хода работы используйте `POST /chat/stream` с тем же JSON и заголовком `X-Actor-ID`. Он возвращает Server-Sent Events: `status`, `session`, `tool_call` (название и аргументы), `tool_result` (результат), затем `done` с ответом или `error`. Терминальный клиент использует этот маршрут и показывает события по мере поступления; длинные результаты инструмента в потоке ограничены 20 000 символов.

## Инструменты

`query_deanery` читает новую схему `deanery`: один `SELECT` с перечислением столбцов и обязательным `LIMIT` от 1 до 60. `OFFSET` разрешён. Запрос выполняется от роли `deanery_read` в транзакции `READ ONLY` с тайм-аутом 5 секунд. Представления `v_students`, `v_grades`, `v_debtors`, `v_schedule_calendar` и другие дают предметные данные. Список столбцов можно получить из `information_schema.columns`. Записывающий SQL через этот инструмент не выполняется.

Агенту доступны `query_deanery`, `propose_sql_change` и `search_regulations`. `propose_sql_change` принимает один `INSERT` или `UPDATE` с простыми значениями для 10 рабочих таблиц: `document_request`, `academic_work`, `grade`, `attendance`, `grade_sheet`, `practice_placement`, `teaching_assignment`, `schedule_slot`, `organization_contact`, `contact_person`. `UPDATE` обязан выбирать одну запись по первичному ключу. Предпросмотр выполняется в откатываемой транзакции; ограничения и триггеры базы проверяются на ней. Старые предметные инструменты сохранены в коде для совместимости с демонстрационными таблицами `public`, но агент их не получает.

Скрипты из `бд/` устанавливаются в ту же базу PostgreSQL, что и приложение, в отдельную схему. `01_schema.sql` удаляет существующую схему `deanery`, поэтому его можно применять только при первоначальной установке либо на копии базы. После `01_schema.sql`, `02_views_functions.sql`, `03_seed.sql`, `05_roles_security.sql` выполните `.venv/bin/python scripts/setup_deanery_read.py` от локального администратора PostgreSQL: скрипт создаст отдельную роль чтения, выдаст приложению права роли `deanery_agent` и запишет секреты в `.env`. Затем выполните `.venv/bin/alembic upgrade head`. Прогон `06_tests.sql` должен завершиться строкой «Все проверки пройдены».

В `бд/03_seed.sql` теперь большой синтетический набор из `бд/generate_seed.py`: 508 студентов, 22 группы, история 2023–2026 годов, расписание осени 2026/27 и посещаемость до 28 сентября 2026 включительно. Генератор детерминирован; даты сценариев фиксированы. `бд/INTEGRITY_RULES.md` — описание правил из приложенного пакета, а не инструкция запуска; оно относится к более новой версии исходной схемы. Для совместимости добавлены поля `group_letter` с проверкой формата и уникальности. Согласованность шифров с учебными планами проверяется в тестах; автоматическая проверка префикса при изменениях пока не реализована. Исходный архив `бд/deanery_db.zip` содержит прежний маленький набор и больше не совпадает с рабочими SQL-файлами.

### Большой тестовый набор: перезагрузка и проверка

На этой машине данные уже загружены. Все команды ниже выполняются из корня проекта:

```bash
cd "/Users/sbogo/Documents/ChatGPT/бд проект"
# Необязательно: снова заменить весь deanery тестовыми данными.
# Скрипт сначала сохраняет полную резервную копию в .data/backups,
# затем атомарно пересоздаёт deanery; таблицы приложения в public сохраняются.
.venv/bin/python scripts/reset_deanery.py

# Проверки целостности и прав (изменения откатываются).
psql -X -d dean_agent -v ON_ERROR_STOP=1 -f бд/06_tests.sql
# Обзор студентов, долгов, пересдач, расписания и посещаемости.
psql -X -d dean_agent -v ON_ERROR_STOP=1 -f бд/08_smoke_queries.sql
# Тесты приложения; полному прогону нужен доступный Qdrant и BGE-M3.
.venv/bin/python -m pytest -q
# Отдельно проверки SQL-чтения и подтверждения изменений, без BGE-M3.
.venv/bin/python -m pytest -q tests/test_sql_query.py tests/test_sql_changes.py

# Если API остановлен, запустить его в отдельном терминале.
.venv/bin/python -m uvicorn dean_agent.api:app --host 127.0.0.1 --port 8080
```

Если API уже работает, сразу запустите `.venv/bin/python scripts/chat_cli.py --actor kuznetsova`. Примеры вопросов: «Сколько сейчас студентов по статусам?», «Покажи должников ИДБ-23-11», «Какие пересдачи открыты на октябрь 2026?», «Покажи расписание ИДБ-23-11 с 5 по 10 октября 2026». Для проверки API:

```bash
curl -sS http://127.0.0.1:8080/health
curl -sS http://127.0.0.1:8080/health/vector
curl -sS -X POST http://127.0.0.1:8080/chat \
  -H 'Content-Type: application/json' -H 'X-Actor-ID: kuznetsova' \
  -d '{"message":"Сколько студентов сейчас обучается, в академическом отпуске и отчислено?"}'
```

Ожидаемый результат по статусам: **494 / 3 / 11**. SQL-тесты завершаются строкой **«Все проверки пройдены»**. Скрипт `scripts/seed_demo.py` относится к прежним таблицам `public` и для этого набора не нужен.

Нормативные документы загружаются через `POST /regulations` как PDF с текстовым слоем, DOCX или UTF-8 TXT. Текст и метаданные хранятся в PostgreSQL; BGE-M3 строит dense и sparse векторы размерности 1024/словарных токенов, Qdrant хранит векторы и делает RRF fusion. Результат поиска возвращает название, источник, страницу и цитируемый фрагмент из PostgreSQL. Проверка статуса индексации: `GET /regulations/{id}`; повторная индексация: `POST /regulations/{id}/reindex`. Для ранее загруженных документов: `.venv/bin/python scripts/reindex_regulations.py`. Сканам пока нужен внешний OCR. Для демонстрации в `docs/` лежат три DOCX с текстом положений СТАНКИНа; их можно загрузить через API. После загрузки сверяйте ответ с оригиналом: в DOCX есть ошибки распознавания текста.

Для загрузки демонстрационных документов в новую базу:

```bash
for file in docs/*.docx; do
  curl -sS -H 'X-Actor-ID: demo-setup' -F "file=@$file" http://127.0.0.1:8080/regulations
done
```

При загрузке можно передать поля формы `title` и `source` (ссылка на оригинал). DOCX не содержит надежной привязки текста к страницам, поэтому в ответах поиск указывает документ и фрагмент без номера страницы.

Для изменения SQL агент возвращает `proposal_id`, описание причины и проверенный предпросмотр. Сотрудник может открыть предложение и подтвердить или отклонить его через `.venv/bin/python scripts/review_sql_proposal.py <proposal_id> --actor kuznetsova` (здесь `kuznetsova` — тестовый логин сотрудника в `deanery.app_user`). В API доступны `GET /sql-proposals/{id}` и `POST /sql-proposals/{id}/decision` с `{"approve":true,"reason":"..."}`; им нужны `X-Actor-ID` с действующим логином сотрудника и `X-Approval-Token` из локального `.env`. При подтверждении база повторно сверяет исходную запись и одной транзакцией пишет изменение, запрос агента и аудит. `DELETE`, `ALTER TABLE`, прямое изменение статуса/группы студента, приказы, отпуска и стипендии не входят в этот маршрут; движения студентов должны использовать процедуры базы.

## Границы текущей версии

Это локальный прототип: `X-Actor-ID` передаётся клиентом и сам по себе не удостоверяет личность; ключ подтверждения общий для сотрудников. Для реальных персональных данных нужна индивидуальная аутентификация и авторизация. `ALTER TABLE` следует оформлять отдельной административной миграцией с анализом зависимостей и блокировок; агентский SQL-инструмент его не принимает. Отдельный OCR и генерация документов пока не включены. Фото и сканы читаются визуальной моделью; точность реквизитов нужно сверять с оригиналом. Текст документов отправляется на `mlspace` для вычисления embeddings, а Qdrant и PostgreSQL хранят данные локально.


## Вложения и интеграция с backend_dean

**Бэкенд — [PurpleCloudy](https://github.com/PurpleCloudy).**
Оригинальный репозиторий: [PurpleCloudy/backend_dean](https://github.com/PurpleCloudy/backend_dean).

Бэкенд добавлен отдельной папкой [`backend_dean/`](backend_dean/) в этот
репозиторий с сохранением лицензии и авторства. В локальную версию внесены
изменения для приёма документов, фото и сканов PDF и подключения нашего агента.
Инструкции бэкенда: [`backend_dean/README.md`](backend_dean/README.md).
Обновлённый агент включён в
`backend_dean/references/dean-agent`; адаптер использует аутентификацию, привязку
версий, ограничения доступа и подписанные запросы бэкенда. Для переноса следующих
изменений агента: `.venv/bin/python scripts/sync_backend_agent.py`.

Прямой API агента принимает multipart-запросы `POST /chat/files` и
`POST /chat/files/stream`: поля `message`, необязательный `session_id`, повторяемое
поле `files`, заголовок `X-Actor-ID`. Поддерживаются PDF, DOCX, UTF-8 TXT/CSV,
PNG, JPEG и WEBP. До пяти файлов, до 10 МБ на файл и 20 МБ на запрос.

```bash
curl -sS http://127.0.0.1:8080/chat/files \
  -H 'X-Actor-ID: demo-staff' \
  -F 'message=Прочитай заявление и проверь реквизиты на фото' \
  -F 'files=@statement.docx' -F 'files=@photo.jpg'
```

Текст документов передаётся модели с названием, страницами и отметками качества;
фото — как изображения. Сканы PDF передаются изображениями первых десяти страниц.
Ограничение визуальных страниц и сокращение текста отмечаются в контексте.
Нужна модель, поддерживающая изображения; настроенная модель прошла проверку
текстового файла и фото. Исходные изображения не записываются в историю чата.

В бэкенде используйте `POST /api/v1/files`, дождитесь успешной обработки через
`GET /api/v1/jobs/{id}`, затем передайте точные `file_id` и `version_id` в
`POST /api/v1/agent/chat` или `/stream`. `/api/v1/agent/capabilities` теперь
сообщает `agent_supported: true`. Агент читает только вложения текущего запроса;
длинные документы дочитывает через `read_attachment_text`. Обычный JSON-чат
сохраняет прежний контракт. Прямые multipart-маршруты закрыты в защищённом адаптере.

Проверка без Docker (локальный PostgreSQL и существующий Qdrant на порту 6333):

```bash
.venv/bin/pip install -e '.[dev]' './backend_dean[test]'
.venv/bin/python -m pytest -q tests/test_attachments.py
.venv/bin/python backend_dean/tests/run_local_attachment_integration.py
```

Интеграционный скрипт создаёт и удаляет отдельную тестовую базу и временные роли;
рабочая база агента и существующая коллекция Qdrant сохраняются. Используются
настоящие HTTP-серверы, DeepAgents, PostgreSQL, очередь задач и локальный Qdrant;
S3, антивирус, embeddings и LLM заменены явно заданными тестовыми провайдерами.
Результат — `backend_dean/.local/test-results/attachments-local.json`.
Для полного запуска бэкенда нужны S3 и ClamAV; Docker — один из способов их запуска.
На macOS парсер ограничен размером, пикселями, временем и CPU; лимит памяти на
уровне ОС применяется в Linux-развёртывании.
