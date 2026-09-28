"""Rebuild local Qdrant vectors from PostgreSQL regulation chunks."""

from sqlalchemy import select

from dean_agent.db import SessionLocal
from dean_agent.models import Regulation
from dean_agent.vector_search import index_regulation


def main() -> None:
    with SessionLocal() as db:
        ids = db.scalars(select(Regulation.id).order_by(Regulation.id)).all()
    for regulation_id in ids:
        count = index_regulation(regulation_id)
        print(f"Regulation {regulation_id}: indexed {count} chunks")
    print(f"Reindexed {len(ids)} regulations")


if __name__ == "__main__":
    main()
