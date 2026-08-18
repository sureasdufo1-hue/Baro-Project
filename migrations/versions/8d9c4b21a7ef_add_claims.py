"""add claims and accidents

Revision ID: 8d9c4b21a7ef
Revises: 3f8261322bcf
Create Date: 2026-08-18
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "8d9c4b21a7ef"
down_revision: str | None = "3f8261322bcf"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    if op.get_bind().dialect.name == "postgresql":
        for value in (
            "CLAIM_CREATE",
            "CLAIM_MODIFY",
            "CLAIM_CANCEL",
            "CLAIM_STATUS_CHANGE",
            "ACCIDENT_CREATE",
            "ACCIDENT_MODIFY",
        ):
            op.execute(f"ALTER TYPE auditeventtype ADD VALUE IF NOT EXISTS '{value}'")
    claim_type = sa.Enum("DISEASE", "INJURY", "OTHER", name="claimtype")
    claim_status = sa.Enum(
        "DRAFT",
        "DOCUMENT_REQUIRED",
        "DOCUMENT_PROCESSING",
        "USER_VERIFICATION",
        "ASSESSING",
        "MANUAL_REVIEW",
        "COMPLETED",
        "FAILED",
        "CANCELLED",
        "CLOSED",
        name="claimstatus",
    )
    op.create_table(
        "claims",
        sa.Column("claim_id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("insured_id", sa.Uuid(), nullable=False),
        sa.Column("contract_id", sa.Uuid(), nullable=False),
        sa.Column("claim_number", sa.String(length=40), nullable=False),
        sa.Column("claim_type", claim_type, nullable=False),
        sa.Column("status", claim_status, nullable=False),
        sa.Column("title", sa.String(length=200), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("completed_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(["user_id"], ["users.user_id"]),
        sa.ForeignKeyConstraint(["insured_id"], ["insureds.insured_id"]),
        sa.ForeignKeyConstraint(["contract_id"], ["insurance_contracts.contract_id"]),
        sa.PrimaryKeyConstraint("claim_id"),
        sa.UniqueConstraint("claim_number"),
    )
    for columns, name in (
        (["user_id"], "ix_claims_user_id"),
        (["insured_id"], "ix_claims_insured_id"),
        (["contract_id"], "ix_claims_contract_id"),
        (["claim_number"], "ix_claims_claim_number"),
        (["claim_type"], "ix_claims_claim_type"),
        (["status"], "ix_claims_status"),
        (["user_id", "status"], "ix_claims_user_status"),
        (["user_id", "created_at"], "ix_claims_user_created_at"),
    ):
        op.create_index(name, "claims", columns)
    op.create_table(
        "accidents",
        sa.Column("accident_id", sa.Uuid(), nullable=False),
        sa.Column("claim_id", sa.Uuid(), nullable=False),
        sa.Column(
            "accident_type",
            claim_type,
            nullable=False,
        ),
        sa.Column("accident_date", sa.Date(), nullable=True),
        sa.Column("diagnosis_date", sa.Date(), nullable=True),
        sa.Column("onset_date", sa.Date(), nullable=True),
        sa.Column("description", sa.Text(), nullable=True),
        sa.Column("location", sa.String(length=300), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["claim_id"], ["claims.claim_id"]),
        sa.PrimaryKeyConstraint("accident_id"),
        sa.UniqueConstraint("claim_id", name="uq_accidents_claim_id"),
    )
    op.create_index("ix_accidents_claim_id", "accidents", ["claim_id"], unique=True)


def downgrade() -> None:
    op.drop_index("ix_accidents_claim_id", table_name="accidents")
    op.drop_table("accidents")
    for name in (
        "ix_claims_user_created_at",
        "ix_claims_user_status",
        "ix_claims_status",
        "ix_claims_claim_type",
        "ix_claims_claim_number",
        "ix_claims_contract_id",
        "ix_claims_insured_id",
        "ix_claims_user_id",
    ):
        op.drop_index(name, table_name="claims")
    op.drop_table("claims")
    if op.get_bind().dialect.name == "postgresql":
        op.execute("DROP TYPE IF EXISTS claimstatus")
        op.execute("DROP TYPE IF EXISTS claimtype")
