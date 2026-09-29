"""Store reviewed deanery SQL changes.

Revision ID: 4b5c6d7e8f90
Revises: 3a4b5c6d7e8f
"""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision = "4b5c6d7e8f90"
down_revision = "3a4b5c6d7e8f"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "sql_change_proposals",
        sa.Column("id", sa.UUID(), primary_key=True),
        sa.Column("actor_id", sa.String(128), nullable=False),
        sa.Column("agent_run_id", sa.String(128), nullable=False),
        sa.Column("sql_text", sa.Text(), nullable=False),
        sa.Column("explanation", sa.Text(), nullable=False),
        sa.Column("reason", sa.Text(), nullable=False),
        sa.Column("preview", postgresql.JSONB(), nullable=False),
        sa.Column("status", sa.String(20), nullable=False),
        sa.Column("decision_reason", sa.Text()),
        sa.Column("decided_by", sa.String(128)),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("resolved_at", sa.DateTime(timezone=True)),
    )
    op.create_index("ix_sql_change_proposals_status", "sql_change_proposals", ["status"])


def downgrade():
    op.drop_index("ix_sql_change_proposals_status", table_name="sql_change_proposals")
    op.drop_table("sql_change_proposals")
