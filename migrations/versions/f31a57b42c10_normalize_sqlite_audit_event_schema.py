"""normalize SQLite audit event schema

Revision ID: f31a57b42c10
Revises: d12044c5a901
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "f31a57b42c10"
down_revision: str | None = "d12044c5a901"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    if op.get_bind().dialect.name == "sqlite":
        with op.batch_alter_table("audit_logs") as batch:
            batch.alter_column(
                "event_type",
                existing_type=sa.String(length=13),
                type_=sa.String(length=32),
                existing_nullable=False,
            )


def downgrade() -> None:
    if op.get_bind().dialect.name == "sqlite":
        with op.batch_alter_table("audit_logs") as batch:
            batch.alter_column(
                "event_type",
                existing_type=sa.String(length=32),
                type_=sa.String(length=13),
                existing_nullable=False,
            )
