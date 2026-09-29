"""Persist agent chat context.

Revision ID: 5c6d7e8f9012
Revises: 4b5c6d7e8f90
"""
from alembic import op
import sqlalchemy as sa

revision = "5c6d7e8f9012"
down_revision = "4b5c6d7e8f90"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table("chat_sessions",
                    sa.Column("id", sa.UUID(), primary_key=True),
                    sa.Column("actor_id", sa.String(128), nullable=False),
                    sa.Column("created_at", sa.DateTime(timezone=True), nullable=False))
    op.create_index("ix_chat_sessions_actor_id", "chat_sessions", ["actor_id"])
    op.create_table("chat_messages",
                    sa.Column("id", sa.Integer(), primary_key=True),
                    sa.Column("session_id", sa.UUID(), sa.ForeignKey("chat_sessions.id", ondelete="CASCADE"), nullable=False),
                    sa.Column("role", sa.String(20), nullable=False),
                    sa.Column("content", sa.Text(), nullable=False),
                    sa.Column("created_at", sa.DateTime(timezone=True), nullable=False))
    op.create_index("ix_chat_messages_session_id", "chat_messages", ["session_id"])


def downgrade():
    op.drop_index("ix_chat_messages_session_id", table_name="chat_messages")
    op.drop_table("chat_messages")
    op.drop_index("ix_chat_sessions_actor_id", table_name="chat_sessions")
    op.drop_table("chat_sessions")
