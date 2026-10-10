"""Opt-in real PostgreSQL/Uvicorn/DeepAgents test with explicit provider fixtures.

Run from the parent workspace:
  .venv/bin/python backend_dean/tests/run_local_attachment_integration.py
Requires a local PostgreSQL administrator connection (defaults to postgresql:///postgres).
Creates and drops an isolated database and temporary login roles. S3, scanner,
BGE, Qdrant and LLM are deterministic fixtures, not production-service checks.
"""
import asyncio
from contextlib import asynccontextmanager
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import threading
import time
from uuid import uuid4

ROOT = Path(__file__).resolve().parents[1]
WORKSPACE = ROOT.parent
sys.path[:0] = [str(ROOT / 'backend'), str(ROOT), str(WORKSPACE)]
import httpx
from PIL import Image
import psycopg
from psycopg import sql
import pymupdf
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
import uvicorn


def port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


class Model(BaseHTTPRequestHandler):
    requests = []
    def log_message(self, *_):
        pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        self.requests.append(body)
        messages = body['messages']
        last = max(i for i, m in enumerate(messages) if m['role'] == 'user')
        content = messages[last]['content']
        blocks = content if isinstance(content, list) else [{'type': 'text', 'text': content}]
        text = '\n'.join(b.get('text', '') for b in blocks)
        results = [m['content'] for m in messages[last+1:] if m['role'] == 'tool']
        if 'READ_NEXT:' in text and not results:
            version = text.split('READ_NEXT:', 1)[1].split()[0]
            message = {'role': 'assistant', 'content': None, 'tool_calls': [{'id': 'read-next', 'type': 'function',
                'function': {'name': 'read_attachment_text', 'arguments': json.dumps({'version_id': version, 'offset': 20, 'limit': 20})}}]}
            finish = 'tool_calls'
        else:
            message = {'role': 'assistant', 'content': json.dumps({'text': text, 'images': sum(b['type'] == 'image_url' for b in blocks),
                'tool_results': results}, ensure_ascii=False)}
            finish = 'stop'
        raw = json.dumps({'id': 'chatcmpl-test', 'object': 'chat.completion', 'created': 0, 'model': 'fixture',
            'choices': [{'index': 0, 'message': message, 'finish_reason': finish}], 'usage': {'prompt_tokens': 1, 'completion_tokens': 1, 'total_tokens': 2}}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


def main():
    suffix = uuid4().hex[:12]
    database = 'attachment_test_' + suffix
    runtime, upstream = 'attachment_runtime_' + suffix, 'attachment_upstream_' + suffix
    password = secrets.token_hex(24)
    owner_url = os.getenv('LOCAL_TEST_ADMIN_URL', 'postgresql:///postgres')
    admin = psycopg.connect(owner_url, autocommit=True)
    admin.execute(sql.SQL('CREATE DATABASE {}').format(sql.Identifier(database)))
    owner = psycopg.conninfo.make_conninfo(owner_url, dbname=database)
    # Alembic expects a URL; local admin connection uses the OS user by default.
    migration_url = 'postgresql:///' + database
    threads, servers, engines = [], [], []
    model = ThreadingHTTPServer(('127.0.0.1', 0), Model)
    model_thread = threading.Thread(target=model.serve_forever, daemon=True)
    model_thread.start()
    records = []
    try:
        env = {**os.environ, 'MIGRATION_DATABASE_URL': migration_url}
        os.environ['PYTHONPATH'] = os.pathsep.join([str(ROOT / 'backend'), str(ROOT), str(WORKSPACE)])
        subprocess.run([sys.executable, '-m', 'alembic', '-c', 'migrations/alembic.ini', 'upgrade', 'head'], cwd=ROOT, env=env, check=True)
        for role, parent in ((runtime, 'deanery_runtime'), (upstream, 'deanery_upstream')):
            admin.execute(sql.SQL('CREATE ROLE {} LOGIN INHERIT PASSWORD {}').format(sql.Identifier(role), sql.Literal(password)))
            admin.execute(sql.SQL('GRANT {} TO {}').format(sql.Identifier(parent), sql.Identifier(role)))
        with psycopg.connect(owner) as conn:
            rid = conn.execute("INSERT INTO deanery.app_role(code,name) VALUES('admin','Администратор') RETURNING role_id").fetchone()[0]
            person = conn.execute("INSERT INTO deanery.person(last_name,first_name,gender,birth_date) VALUES('Тест','Админ','M','2000-01-01') RETURNING person_id").fetchone()[0]
            from argon2 import PasswordHasher
            conn.execute('INSERT INTO deanery.app_user(person_id,role_id,login,password_hash) VALUES(%s,%s,%s,%s)', (person, rid, 'attachment-admin', PasswordHasher().hash(password)))
        api_port, agent_port = port(), port()
        secret = secrets.token_hex(32)
        runtime_url = f'postgresql://{runtime}:{password}@127.0.0.1/{database}'
        upstream_url = f'postgresql+psycopg://{upstream}:{password}@127.0.0.1/{database}'
        os.environ.update(DELEGATION_SECRET=secret, BACKEND_URL=f'http://127.0.0.1:{api_port}')
        from deanery_api.config import get_settings, Settings
        settings = Settings(_env_file=None, database_url=runtime_url, job_database_url=runtime_url,
            access_token_key=secrets.token_hex(32), delegation_secret=secret, agent_url=f'http://127.0.0.1:{agent_port}',
            development=True, allowed_origins=['http://localhost:5173'], qdrant_url='http://127.0.0.1:6333', qdrant_collection='attachment_test_' + suffix)
        get_settings.cache_clear()
        # All modules import the same function; replace its cached return via env.
        os.environ.update(DATABASE_URL=runtime_url, JOB_DATABASE_URL=runtime_url, ACCESS_TOKEN_KEY=settings.access_token_key,
            AGENT_URL=settings.agent_url, DEVELOPMENT='true', ALLOWED_ORIGINS='["http://localhost:5173"]',
            QDRANT_URL=settings.qdrant_url, QDRANT_COLLECTION=settings.qdrant_collection)
        from deanery_api import storage, worker
        originals = {}
        async def put(key, data, mime): originals[key] = data
        async def delete(key): originals.pop(key, None)
        async def chunks(key, response=None): yield originals[key]
        async def scan(data):
            if b'EICAR' in data:
                from deanery_api.errors import ApiError
                raise ApiError(422, 'malware_detected', 'Fixture scanner rejection')
        async def nothing(*args, **kwargs): return {}
        async def embed(texts): return [{'dense': [1.] + [0.]*1023, 'sparse': {'indices': [1], 'values': [1.]}} for t in texts]
        storage.put_original, storage.delete_original, storage.original_chunks = put, delete, chunks
        storage.scan = scan
        storage.embed = embed
        # download_file calls open_original before consuming original_chunks.
        async def open_original(key): return {'fixture_key': key}
        storage.open_original = open_original
        from dean_agent import agent as original
        from dean_agent.config import settings as agent_settings
        engine = create_engine(upstream_url)
        engines.append(engine)
        original.SessionLocal = sessionmaker(engine, expire_on_commit=False)
        agent_settings.openai_base_url = f'http://127.0.0.1:{model.server_port}/v1'
        agent_settings.openai_model = 'fixture'
        from deanery_api.main import app as api
        from integrations.dean_agent_adapter.app import app as agent
        original_lifespan = api.router.lifespan_context
        @asynccontextmanager
        async def lifespan(app):
            async with original_lifespan(app):
                task = asyncio.create_task(worker.app.run_worker_async(queues=['documents'], concurrency=1))
                try: yield
                finally:
                    task.cancel()
                    await asyncio.gather(task, return_exceptions=True)
        api.router.lifespan_context = lifespan
        for app, app_port in ((api, api_port), (agent, agent_port)):
            server = uvicorn.Server(uvicorn.Config(app, host='127.0.0.1', port=app_port, log_level='error'))
            thread = threading.Thread(target=server.run, daemon=True)
            servers.append(server); threads.append(thread); thread.start()
        deadline = time.monotonic() + 20
        while not all(s.started for s in servers):
            if time.monotonic() > deadline: raise AssertionError('HTTP servers did not start')
            time.sleep(.05)
        with httpx.Client(base_url=f'http://127.0.0.1:{api_port}', trust_env=False, timeout=60, headers={'Origin': 'http://localhost:5173'}) as client:
            login = client.post('/api/v1/auth/login', json={'login': 'attachment-admin', 'password': password})
            assert login.status_code == 200, login.text
            client.headers['Authorization'] = 'Bearer ' + login.json()['access_token']
            cap = client.get('/api/v1/agent/capabilities')
            assert cap.json()['attachment_context']['agent_supported'] is True, cap.text
            records.append('signed capability discovery')
            def upload(filename, raw, mime):
                response = client.post('/api/v1/files', headers={'Idempotency-Key': uuid4().hex}, data={'title': filename}, files={'file': (filename, raw, mime)})
                assert response.status_code == 202, response.text
                value = response.json()
                deadline = time.monotonic() + 40
                while True:
                    job = client.get('/api/v1/jobs/' + value['job']['id']).json()
                    if job['status'] in ('succeeded', 'failed'): break
                    if time.monotonic() > deadline: raise AssertionError(job)
                    time.sleep(.1)
                return value, job
            output = io.BytesIO(); Image.new('RGB', (60, 40), 'red').save(output, format='PNG')
            photo, job = upload('photo.png', output.getvalue(), 'image/png')
            assert job['status'] == 'succeeded' and job['result']['chunks'] == 0, job
            text, job = upload('document.txt', ('Уникальный текст заявления. ' * 1500).encode(), 'text/plain')
            assert job['status'] == 'succeeded', job
            with pymupdf.open() as doc:
                page = doc.new_page(width=100, height=100); page.insert_image(page.rect, stream=output.getvalue())
                scan_pdf, job = upload('scan.pdf', doc.tobytes(), 'application/pdf')
            assert job['status'] == 'succeeded' and job['result']['chunks'] == 0, job
            records.append('HTTP uploads + durable queue + worker parsing: text, photo, scanned PDF')
            refs = [{k: file[k] for k in ('file_id', 'version_id')} for file in (text, photo, scan_pdf)]
            payload = {'message': 'READ_NEXT:' + text['version_id'], 'attachments': refs}
            response = client.post('/api/v1/agent/chat', json=payload)
            assert response.status_code == 200, response.text
            answer = response.json(); observed = json.loads(answer['answer'])
            assert observed['images'] == 2 and 'Уникальный текст заявления' in observed['text'], observed
            assert answer['tools_used'] == ['read_attachment_text']
            assert json.loads(observed['tool_results'][0])['chunks'][0]['ordinal'] == 20
            context = answer['attachment_context']
            assert client.get('/api/v1/agent/runs/' + context['backend_run_id'] + '/attachments').status_code == 200
            records.append('real DeepAgents HTTP model input: document text + photo + scanned PDF + signed pagination tool')
            response = client.post('/api/v1/agent/chat/stream', json={**payload, 'session_id': answer['session_id']})
            assert response.status_code == 200 and 'event: done' in response.text and 'event: error' not in response.text, response.text
            records.append('SSE + context propagation + conversation history')
            invalid = client.post('/api/v1/agent/chat', json={'message': 'read', 'attachments': [refs[0], refs[0]]})
            assert invalid.status_code == 422, invalid.text
            invalid = client.post('/api/v1/agent/chat', json={'message': 'read', 'attachments': [{'file_id': str(uuid4()), 'version_id': str(uuid4())}]})
            assert invalid.status_code == 404, invalid.text
            assert client.get('/api/v1/files/' + photo['file_id']).json()['versions'][0]['mime'] == 'image/png'
            assert client.get('/api/v1/files/' + photo['file_id'] + '/versions/' + photo['version_id'] + '/download').content == output.getvalue()
            bad, job = upload('infected.txt', b'EICAR fixture', 'text/plain')
            assert job['status'] == 'failed' and job['error_code'] == 'malware_detected', job
            rejected = client.post('/api/v1/agent/chat', json={'message': 'read', 'attachments': [{k: bad[k] for k in ('file_id', 'version_id')}]})
            assert rejected.status_code == 409, rejected.text
            records.append('duplicate/missing/rejected attachments denied + immutable original download')
            plain = client.post('/api/v1/agent/chat', json={'message': 'hello'})
            assert plain.status_code == 200 and set(plain.json()) == {'run_id', 'session_id', 'answer', 'proposals', 'tools_used'}, plain.text
            records.append('text-only wire compatibility')
        with httpx.Client(base_url=f'http://127.0.0.1:{agent_port}', trust_env=False) as client:
            assert client.post('/chat', json={'message': 'read'}).status_code == 401
            assert client.post('/chat/files', json={}).status_code == 404
        records.append('unsigned adapter access denied')
        print('\n'.join('PASS ' + row for row in records))
    finally:
        for server in servers: server.should_exit = True
        for thread in threads: thread.join(timeout=10)
        for engine in engines: engine.dispose()
        model.shutdown(); model_thread.join(timeout=2); model.server_close()
        admin.execute(sql.SQL('DROP DATABASE {} WITH (FORCE)').format(sql.Identifier(database)))
        for role in (runtime, upstream):
            admin.execute(sql.SQL('DROP ROLE IF EXISTS {}').format(sql.Identifier(role)))
        admin.close()
        httpx.delete("http://127.0.0.1:6333/collections/attachment_test_" + suffix, trust_env=False, timeout=5)
        destination = ROOT / '.local/test-results/attachments-local.json'
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(json.dumps({'passed': records, 'providers': 'S3/scanner/BGE/LLM fixtures; PostgreSQL, local Qdrant, HTTP, queue and agent real',
            'database_removed': database}, ensure_ascii=False, indent=2))


if __name__ == '__main__': main()
