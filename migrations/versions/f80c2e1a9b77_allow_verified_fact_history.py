"""allow verified fact history

Revision ID: f80c2e1a9b77
Revises: f31a57b42c10
"""

from collections.abc import Sequence

from alembic import op

revision: str = "f80c2e1a9b77"
down_revision: str | None = "f31a57b42c10"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    with op.batch_alter_table("verified_facts") as batch:
        batch.drop_constraint("uq_verified_facts_extracted_fact_id", type_="unique")


def downgrade() -> None:
    with op.batch_alter_table("verified_facts") as batch:
        batch.create_unique_constraint("uq_verified_facts_extracted_fact_id", ["extracted_fact_id"])
