"""add benefit calculations

Revision ID: f64b8d30ce12
Revises: e53a7c29bd01
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "f64b8d30ce12"
down_revision: str | None = "e53a7c29bd01"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    if op.get_bind().dialect.name == "postgresql":
        for value in (
            "CALCULATION_EXECUTE",
            "CALCULATION_COMPLETE",
            "CALCULATION_FAILED",
            "CALCULATION_RECALCULATE",
            "CALCULATION_VERSION_CREATED",
        ):
            op.execute(f"ALTER TYPE auditeventtype ADD VALUE IF NOT EXISTS '{value}'")
    op.create_table(
        "benefit_calculations",
        sa.Column("calculation_id", sa.Uuid(), nullable=False),
        sa.Column("claim_id", sa.Uuid(), nullable=False),
        sa.Column("assessment_id", sa.Uuid(), nullable=False),
        sa.Column("contract_coverage_id", sa.Uuid(), nullable=False),
        sa.Column("rule_version_id", sa.Uuid(), nullable=True),
        sa.Column("calculation_version", sa.Integer(), nullable=False),
        sa.Column("previous_calculation_id", sa.Uuid(), nullable=True),
        sa.Column("is_current", sa.Boolean(), nullable=False),
        sa.Column("calculation_fingerprint", sa.String(64), nullable=False),
        sa.Column("currency", sa.String(3), nullable=False),
        sa.Column("insured_amount_snapshot", sa.BigInteger(), nullable=False),
        sa.Column("payment_rate_snapshot", sa.Numeric(12, 6), nullable=True),
        sa.Column("calculation_formula", sa.Text(), nullable=False),
        sa.Column("calculation_input", sa.JSON(), nullable=False),
        sa.Column("gross_amount", sa.BigInteger(), nullable=False),
        sa.Column("deduction_amount", sa.BigInteger(), nullable=False),
        sa.Column("final_amount", sa.BigInteger(), nullable=False),
        sa.Column(
            "calculation_status",
            sa.Enum(
                "PENDING",
                "CALCULATED",
                "NOT_PAYABLE",
                "MANUAL_REVIEW",
                "FAILED",
                "SUPERSEDED",
                name="calculationstatus",
            ),
            nullable=False,
        ),
        sa.Column("calculated_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["claim_id"], ["claims.claim_id"]),
        sa.ForeignKeyConstraint(["assessment_id"], ["coverage_assessments.assessment_id"]),
        sa.ForeignKeyConstraint(
            ["contract_coverage_id"], ["contract_coverages.contract_coverage_id"]
        ),
        sa.ForeignKeyConstraint(["rule_version_id"], ["rule_versions.rule_version_id"]),
        sa.ForeignKeyConstraint(
            ["previous_calculation_id"], ["benefit_calculations.calculation_id"]
        ),
        sa.PrimaryKeyConstraint("calculation_id"),
        sa.UniqueConstraint(
            "assessment_id", "calculation_fingerprint", name="uq_calculation_fingerprint"
        ),
        sa.UniqueConstraint("assessment_id", "calculation_version", name="uq_calculation_version"),
    )
    for cols, name in (
        (["claim_id"], "ix_benefit_calculations_claim_id"),
        (["assessment_id"], "ix_benefit_calculations_assessment_id"),
        (["contract_coverage_id"], "ix_benefit_calculations_contract_coverage_id"),
        (["rule_version_id"], "ix_benefit_calculations_rule_version_id"),
        (["is_current"], "ix_benefit_calculations_is_current"),
        (["calculation_status"], "ix_benefit_calculations_calculation_status"),
    ):
        op.create_index(name, "benefit_calculations", cols)


def downgrade() -> None:
    op.drop_table("benefit_calculations")
    if op.get_bind().dialect.name == "postgresql":
        op.execute("DROP TYPE IF EXISTS calculationstatus")
