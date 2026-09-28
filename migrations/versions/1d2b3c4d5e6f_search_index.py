"""Russian full-text search index for regulation chunks."""

from alembic import op

revision = "1d2b3c4d5e6f"
down_revision = "ec6d4a5873d3"
branch_labels = None
depends_on = None


def upgrade():
    op.execute("CREATE INDEX ix_regulation_chunks_fts ON regulation_chunks USING GIN (to_tsvector('russian', content))")
    op.execute("ALTER TABLE grades ADD CONSTRAINT ck_grades_status CHECK (status IN ('passed', 'debt', 'pending'))")
    op.execute("ALTER TABLE grades ADD CONSTRAINT ck_grades_value CHECK (value IS NULL OR value BETWEEN 2 AND 5)")


def downgrade():
    op.execute("ALTER TABLE grades DROP CONSTRAINT ck_grades_value")
    op.execute("ALTER TABLE grades DROP CONSTRAINT ck_grades_status")
    op.execute("DROP INDEX ix_regulation_chunks_fts")
