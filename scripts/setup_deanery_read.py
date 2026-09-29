"""Create a separate PostgreSQL login for the agent's read-only SQL tool."""

from pathlib import Path
import secrets
import sys

import psycopg
from psycopg import sql
from sqlalchemy.engine import make_url

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from dean_agent.config import settings

url = make_url(settings.database_url)
if not url.database:
    raise SystemExit("DATABASE_URL must specify a database")
password = secrets.token_urlsafe(36)
role = "deanery_query"
with psycopg.connect(dbname=url.database) as conn:
    with conn.cursor() as cur:
        cur.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (role,))
        if cur.fetchone():
            cur.execute(sql.SQL("ALTER ROLE {} LOGIN PASSWORD {}").format(
                sql.Identifier(role), sql.Literal(password)))
        else:
            cur.execute(sql.SQL("CREATE ROLE {} LOGIN PASSWORD {}").format(
                sql.Identifier(role), sql.Literal(password)))
        cur.execute(sql.SQL("GRANT deanery_read TO {}").format(sql.Identifier(role)))
        if url.username:
            cur.execute(sql.SQL("REVOKE deanery_read FROM {}").format(
                sql.Identifier(url.username)))
            cur.execute(sql.SQL("GRANT deanery_agent TO {}").format(
                sql.Identifier(url.username)))

read_url = url.set(username=role, password=password)
env_path = ROOT / ".env"
lines = env_path.read_text().splitlines() if env_path.exists() else []
lines = [line for line in lines if not line.startswith("DEANERY_READ_URL=")]
lines.append(f"DEANERY_READ_URL={read_url.render_as_string(hide_password=False)}")
if not any(line.startswith("DEANERY_APPROVAL_TOKEN=") and line.split("=", 1)[1] for line in lines):
    lines = [line for line in lines if not line.startswith("DEANERY_APPROVAL_TOKEN=")]
    lines.append(f"DEANERY_APPROVAL_TOKEN={secrets.token_urlsafe(36)}")
env_path.write_text("\n".join(lines) + "\n")
env_path.chmod(0o600)
print("Configured deanery_query, writer membership and approval token in .env")
