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
  -d '{"message":"Кто в ДЕМО-24-01 имеет больше двух задолженностей?"}'
```

## Инструменты

`search_students`, `get_student_profile`, `get_grades`, `get_academic_debts`, `get_attendance`, `get_group_statistics`, `search_regulations`, `propose_student_group_change`.

Нормативные документы загружаются через `POST /regulations` как PDF с текстовым слоем, DOCX или UTF-8 TXT. Текст и метаданные хранятся в PostgreSQL; BGE-M3 строит dense и sparse векторы размерности 1024/словарных токенов, Qdrant хранит векторы и делает RRF fusion. Результат поиска возвращает название, источник, страницу и цитируемый фрагмент из PostgreSQL. Проверка статуса индексации: `GET /regulations/{id}`; повторная индексация: `POST /regulations/{id}/reindex`. Для ранее загруженных документов: `.venv/bin/python scripts/reindex_regulations.py`. Сканам пока нужен внешний OCR. Для демонстрации в `docs/` лежат три DOCX с текстом положений СТАНКИНа; их можно загрузить через API. После загрузки сверяйте ответ с оригиналом: в DOCX есть ошибки распознавания текста.

Для загрузки демонстрационных документов в новую базу:

```bash
for file in docs/*.docx; do
  curl -sS -H 'X-Actor-ID: demo-setup' -F "file=@$file" http://127.0.0.1:8080/regulations
done
```

При загрузке можно передать поля формы `title` и `source` (ссылка на оригинал). DOCX не содержит надежной привязки текста к страницам, поэтому в ответах поиск указывает документ и фрагмент без номера страницы.

Для предложения перевода агент возвращает `proposal_id`. Проверить diff можно через `GET /proposals/{id}`. Подтверждение: `POST /proposals/{id}/decision` с `{"approve":true}` и `X-Actor-ID`; отказ — `{"approve":false}`. Подтверждение блокирует строку, проверяет прежнюю группу и выполняет изменение, запись истории и аудит одной транзакцией.

## Границы текущей версии

Это локальный прототип без входа пользователей и ролей: `X-Actor-ID` передаётся клиентом и сам по себе не удостоверяет личность. Не открывайте API наружу с реальными персональными данными до добавления аутентификации и авторизации. OCR, извлечение полей из загруженного приказа и генерация документов пока не включены. Текст документов отправляется на `mlspace` для вычисления embeddings, а Qdrant и PostgreSQL хранят данные локально.
