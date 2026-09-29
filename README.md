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
.venv/bin/python scripts/seed_demo.py  # только синтетические данные
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

Семь SQL-файлов рядом с `бд/deanery_db.zip` побайтно совпадают с одноимёнными файлами внутри архива. Для запуска нужны отдельные SQL-файлы; архив дополнительно содержит инструкции, скрипты сборки и диаграммы. Хранить обе копии SQL для работы приложения не требуется, но архив пока сохранён как исходный пакет проекта.

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

Это локальный прототип: `X-Actor-ID` передаётся клиентом и сам по себе не удостоверяет личность; ключ подтверждения общий для сотрудников. Для реальных персональных данных нужна индивидуальная аутентификация и авторизация. `ALTER TABLE` следует оформлять отдельной административной миграцией с анализом зависимостей и блокировок; агентский SQL-инструмент его не принимает. OCR, извлечение полей из загруженного приказа и генерация документов пока не включены. Текст документов отправляется на `mlspace` для вычисления embeddings, а Qdrant и PostgreSQL хранят данные локально.
