"""add policy verification audit events

Revision ID: d12044c5a901
Revises: c91e7a42d4f0
"""

from collections.abc import Sequence

from alembic import op

revision: str = "d12044c5a901"
down_revision: str | None = "c91e7a42d4f0"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    if op.get_bind().dialect.name == "postgresql":
        for value in ("POLICY_VERIFICATION_REVIEW", "POLICY_VERIFICATION_PROMOTE"):
            op.execute(f"ALTER TYPE auditeventtype ADD VALUE IF NOT EXISTS '{value}'")


def downgrade() -> None:
    # PostgreSQL enum values cannot be removed safely while preserving audit history.
    pass
