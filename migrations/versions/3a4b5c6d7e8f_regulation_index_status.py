"""Track whether each regulation has reached Qdrant."""

from alembic import op
import sqlalchemy as sa

revision = "3a4b5c6d7e8f"
down_revision = "1d2b3c4d5e6f"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("regulations", sa.Column("index_status", sa.String(length=20),
                                            nullable=False, server_default="pending"))


def downgrade():
    op.drop_column("regulations", "index_status")
