"""Replace local deanery fixtures atomically, preserving public application tables."""

import argparse
from datetime import datetime
from pathlib import Path
import subprocess
import sys

import psycopg

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description="Заменить схему deanery большим тестовым сидом; перед загрузкой сохранить всю БД.")
    parser.add_argument("--database", default="dean_agent", help="Локальная база PostgreSQL (вход от владельца через сокет)")
    args = parser.parse_args()
    # Generate before changing the database: a generation error leaves it untouched.
    subprocess.run([sys.executable, str(ROOT / "бд/generate_seed.py")], check=True)
    files = [ROOT / "бд" / name for name in
             ("01_schema.sql", "02_views_functions.sql", "03_seed.sql", "05_roles_security.sql")]
    scripts = [path.read_text(encoding="utf-8") for path in files]
    # The seed's standalone transaction is managed by the enclosing transaction here.
    scripts[2] = scripts[2].replace("\nBEGIN;\n", "\n").replace("\nCOMMIT;", "")
    backup_dir = ROOT / ".data/backups"
    backup_dir.mkdir(parents=True, exist_ok=True)
    backup = backup_dir / f"before_seed_{datetime.now():%Y%m%d_%H%M%S_%f}.dump"
    backup.touch(mode=0o600, exist_ok=False)
    subprocess.run(["pg_dump", "-d", args.database, "-Fc", "-f", str(backup)], check=True)
    print(f"Резервная копия: {backup}", flush=True)
    with psycopg.connect(dbname=args.database) as conn:
        for path, source in zip(files, scripts):
            print(f"Загрузка {path.name}", flush=True)
            conn.execute(source)
        counts = conn.execute("SELECT (SELECT count(*) FROM deanery.student), "
                              "(SELECT count(*) FROM deanery.study_group)").fetchone()
        if counts != (508, 22):
            raise RuntimeError(f"Неверный объём сида: {counts}; загрузка отменена")
    print("Готово: 508 студентов, 22 группы. Таблицы приложения в public сохранены.")


if __name__ == "__main__":
    main()
