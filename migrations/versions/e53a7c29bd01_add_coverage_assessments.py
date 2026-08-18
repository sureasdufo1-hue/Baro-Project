"""add coverage assessments

Revision ID: e53a7c29bd01
Revises: d42f6e18ab90
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "e53a7c29bd01"
down_revision: str | None = "d42f6e18ab90"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    is_postgresql = op.get_bind().dialect.name == "postgresql"
    if is_postgresql:
        for value in (
            "POLICY_VERSION_RESOLVED",
            "POLICY_VERSION_RESOLUTION_FAILED",
            "ASSESSMENT_CREATED",
            "ASSESSMENT_COMPLETED",
        ):
            op.execute(f"ALTER TYPE auditeventtype ADD VALUE IF NOT EXISTS '{value}'")
    op.create_table(
        "coverage_assessments",
        sa.Column("assessment_id", sa.Uuid(), nullable=False),
        sa.Column("claim_id", sa.Uuid(), nullable=False),
        sa.Column("contract_coverage_id", sa.Uuid(), nullable=False),
        sa.Column("policy_version_id", sa.Uuid(), nullable=True),
        sa.Column("rule_version_id", sa.Uuid(), nullable=True),
        sa.Column("calculation_rule_version_id", sa.Uuid(), nullable=True),
        sa.Column(
            "assessment_status",
            sa.Enum(
                "PENDING",
                "EVALUATING",
                "COMPLETED",
                "FAILED",
                "MANUAL_REVIEW",
                name="assessmentstatus",
            ),
            nullable=False,
        ),
        sa.Column("match_score", sa.Numeric(5, 4), nullable=False),
        sa.Column(
            "eligibility_result",
            sa.Enum(
                "PAYABLE",
                "LIKELY_PAYABLE",
                "ADDITIONAL_INFO_REQUIRED",
                "MANUAL_REVIEW",
                "LIKELY_NOT_PAYABLE",
                "POSSIBLE_EXCLUSION",
                "NOT_PAYABLE",
                "UNDETERMINED",
                name="eligibilityresult",
            ),
            nullable=False,
        ),
        sa.Column("exclusion_result", sa.String(100)),
        sa.Column("reduction_result", sa.String(100)),
        sa.Column("reason_summary", sa.Text(), nullable=False),
        sa.Column("resolution_snapshot", sa.JSON(), nullable=False),
        sa.Column("assessed_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["claim_id"], ["claims.claim_id"]),
        sa.ForeignKeyConstraint(
            ["contract_coverage_id"], ["contract_coverages.contract_coverage_id"]
        ),
        sa.ForeignKeyConstraint(["policy_version_id"], ["policy_versions.policy_version_id"]),
        sa.ForeignKeyConstraint(["rule_version_id"], ["rule_versions.rule_version_id"]),
        sa.ForeignKeyConstraint(["calculation_rule_version_id"], ["rule_versions.rule_version_id"]),
        sa.PrimaryKeyConstraint("assessment_id"),
    )
    for cols, name in (
        (["claim_id"], "ix_coverage_assessments_claim_id"),
        (["contract_coverage_id"], "ix_coverage_assessments_contract_coverage_id"),
        (["policy_version_id"], "ix_coverage_assessments_policy_version_id"),
        (["assessment_status"], "ix_coverage_assessments_assessment_status"),
        (["eligibility_result"], "ix_coverage_assessments_eligibility_result"),
        (["claim_id", "created_at"], "ix_coverage_assessments_claim_created"),
    ):
        op.create_index(name, "coverage_assessments", cols)
    rule_type_enum = (
        postgresql.ENUM(
            "ELIGIBILITY",
            "EXCLUSION",
            "REDUCTION",
            "CALCULATION",
            "LIMIT",
            name="ruletype",
            create_type=False,
        )
        if is_postgresql
        else sa.Enum(
            "ELIGIBILITY", "EXCLUSION", "REDUCTION", "CALCULATION", "LIMIT", name="ruletype"
        )
    )
    op.create_table(
        "assessment_rule_results",
        sa.Column("result_id", sa.Uuid(), nullable=False),
        sa.Column("assessment_id", sa.Uuid(), nullable=False),
        sa.Column("rule_version_id", sa.Uuid(), nullable=False),
        sa.Column("rule_type", rule_type_enum, nullable=False),
        sa.Column(
            "result",
            sa.Enum("PASS", "FAIL", "MISSING_INPUT", "ERROR", name="ruleevaluationresult"),
            nullable=False,
        ),
        sa.Column("input_snapshot", sa.JSON(), nullable=False),
        sa.Column("execution_trace", sa.JSON(), nullable=False),
        sa.Column("executed_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["assessment_id"], ["coverage_assessments.assessment_id"]),
        sa.ForeignKeyConstraint(["rule_version_id"], ["rule_versions.rule_version_id"]),
        sa.PrimaryKeyConstraint("result_id"),
    )
    op.create_index(
        "ix_assessment_rule_results_assessment_id", "assessment_rule_results", ["assessment_id"]
    )
    op.create_index(
        "ix_assessment_rule_results_rule_version_id", "assessment_rule_results", ["rule_version_id"]
    )


def downgrade() -> None:
    op.drop_table("assessment_rule_results")
    op.drop_table("coverage_assessments")
    if op.get_bind().dialect.name == "postgresql":
        for name in ("ruleevaluationresult", "eligibilityresult", "assessmentstatus"):
            op.execute(f"DROP TYPE IF EXISTS {name}")
