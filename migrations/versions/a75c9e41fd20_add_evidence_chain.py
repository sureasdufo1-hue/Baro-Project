"""add evidence chain

Revision ID: a75c9e41fd20
Revises: f64b8d30ce12
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "a75c9e41fd20"
down_revision: str | None = "f64b8d30ce12"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    if op.get_bind().dialect.name == "postgresql":
        for value in (
            "EVIDENCE_BUILD",
            "EVIDENCE_VIEW",
            "DECISION_TRACE_VIEW",
            "POLICY_EVIDENCE_VIEW",
        ):
            op.execute(f"ALTER TYPE auditeventtype ADD VALUE IF NOT EXISTS '{value}'")
    evidence_type = sa.Enum(
        "CONTRACT",
        "COVERAGE",
        "POLICY",
        "POLICY_CLAUSE",
        "RULE",
        "VERIFIED_FACT",
        "DOCUMENT",
        "CALCULATION",
        name="evidencetype",
    )
    evidence_role = sa.Enum(
        "SUPPORTS_ELIGIBILITY",
        "SUPPORTS_EXCLUSION",
        "SUPPORTS_REDUCTION",
        "SUPPORTS_LIMIT",
        "SUPPORTS_CALCULATION_INPUT",
        "SUPPORTS_AMOUNT",
        name="evidencerole",
    )
    op.create_table(
        "evidences",
        sa.Column("evidence_id", sa.Uuid(), nullable=False),
        sa.Column("claim_id", sa.Uuid(), nullable=False),
        sa.Column("assessment_id", sa.Uuid(), nullable=False),
        sa.Column("calculation_id", sa.Uuid(), nullable=False),
        sa.Column("evidence_type", evidence_type, nullable=False),
        sa.Column("source_id", sa.Uuid(), nullable=False),
        sa.Column("evidence_role", evidence_role, nullable=False),
        sa.Column("contract_coverage_id", sa.Uuid(), nullable=True),
        sa.Column("policy_version_id", sa.Uuid(), nullable=True),
        sa.Column("policy_clause_id", sa.Uuid(), nullable=True),
        sa.Column("rule_version_id", sa.Uuid(), nullable=True),
        sa.Column("verified_fact_id", sa.Uuid(), nullable=True),
        sa.Column("document_id", sa.Uuid(), nullable=True),
        sa.Column("page_number", sa.Integer(), nullable=True),
        sa.Column("source_bbox", sa.JSON(), nullable=True),
        sa.Column("source_snapshot", sa.JSON(), nullable=False),
        sa.Column("summary", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["claim_id"], ["claims.claim_id"]),
        sa.ForeignKeyConstraint(["assessment_id"], ["coverage_assessments.assessment_id"]),
        sa.ForeignKeyConstraint(["calculation_id"], ["benefit_calculations.calculation_id"]),
        sa.ForeignKeyConstraint(
            ["contract_coverage_id"], ["contract_coverages.contract_coverage_id"]
        ),
        sa.ForeignKeyConstraint(["policy_version_id"], ["policy_versions.policy_version_id"]),
        sa.ForeignKeyConstraint(["policy_clause_id"], ["policy_clauses.clause_id"]),
        sa.ForeignKeyConstraint(["rule_version_id"], ["rule_versions.rule_version_id"]),
        sa.ForeignKeyConstraint(["verified_fact_id"], ["verified_facts.verified_fact_id"]),
        sa.ForeignKeyConstraint(["document_id"], ["medical_documents.document_id"]),
        sa.PrimaryKeyConstraint("evidence_id"),
    )
    for columns, name in (
        (["claim_id"], "ix_evidences_claim_id"),
        (["assessment_id"], "ix_evidences_assessment_id"),
        (["calculation_id"], "ix_evidences_calculation_id"),
        (["evidence_type"], "ix_evidences_evidence_type"),
        (["source_id"], "ix_evidences_source_id"),
        (["evidence_role"], "ix_evidences_evidence_role"),
        (["contract_coverage_id"], "ix_evidences_contract_coverage_id"),
        (["policy_version_id"], "ix_evidences_policy_version_id"),
        (["policy_clause_id"], "ix_evidences_policy_clause_id"),
        (["rule_version_id"], "ix_evidences_rule_version_id"),
        (["verified_fact_id"], "ix_evidences_verified_fact_id"),
        (["document_id"], "ix_evidences_document_id"),
        (["claim_id", "calculation_id"], "ix_evidences_claim_calculation"),
    ):
        op.create_index(name, "evidences", columns)


def downgrade() -> None:
    op.drop_table("evidences")
    if op.get_bind().dialect.name == "postgresql":
        op.execute("DROP TYPE IF EXISTS evidencerole")
        op.execute("DROP TYPE IF EXISTS evidencetype")
