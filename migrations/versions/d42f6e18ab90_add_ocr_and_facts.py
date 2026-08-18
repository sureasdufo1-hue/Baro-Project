"""add OCR and fact verification

Revision ID: d42f6e18ab90
Revises: b71e2a9f4c30
Create Date: 2026-08-18
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "d42f6e18ab90"
down_revision: str | None = "b71e2a9f4c30"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    if op.get_bind().dialect.name == "postgresql":
        for value in (
            "OCR_REQUEST",
            "OCR_COMPLETE",
            "OCR_FAILED",
            "AI_EXTRACTION_COMPLETE",
            "FACT_CONFIRM",
            "FACT_MODIFY",
            "FACT_REJECT",
        ):
            op.execute(f"ALTER TYPE auditeventtype ADD VALUE IF NOT EXISTS '{value}'")
    fact_type = sa.Enum(
        "DIAGNOSIS_NAME",
        "DIAGNOSIS_CODE",
        "DIAGNOSIS_DATE",
        "SURGERY_NAME",
        "SURGERY_DATE",
        "HOSPITAL_ADMISSION_DATE",
        "HOSPITAL_DISCHARGE_DATE",
        "ACCIDENT_DATE",
        "MEDICAL_FACILITY",
        "DOCUMENT_ISSUE_DATE",
        name="facttype",
    )
    op.create_table(
        "ocr_results",
        sa.Column("ocr_result_id", sa.Uuid(), nullable=False),
        sa.Column("document_id", sa.Uuid(), nullable=False),
        sa.Column("provider", sa.String(100), nullable=False),
        sa.Column("model_name", sa.String(100), nullable=False),
        sa.Column("model_version", sa.String(100), nullable=False),
        sa.Column("raw_text", sa.Text(), nullable=True),
        sa.Column("raw_result", sa.JSON(), nullable=True),
        sa.Column("confidence", sa.Numeric(5, 4), nullable=True),
        sa.Column(
            "status",
            sa.Enum(
                "QUEUED",
                "PROCESSING",
                "SUCCEEDED",
                "FAILED",
                "RETRYING",
                "CANCELLED",
                name="ocrstatus",
            ),
            nullable=False,
        ),
        sa.Column("attempt_count", sa.Integer(), nullable=False),
        sa.Column("error_code", sa.String(100), nullable=True),
        sa.Column("processing_started_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("processing_completed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["document_id"], ["medical_documents.document_id"]),
        sa.PrimaryKeyConstraint("ocr_result_id"),
    )
    op.create_index("ix_ocr_results_document_id", "ocr_results", ["document_id"])
    op.create_index("ix_ocr_results_status", "ocr_results", ["status"])
    op.create_table(
        "extracted_facts",
        sa.Column("extracted_fact_id", sa.Uuid(), nullable=False),
        sa.Column("claim_id", sa.Uuid(), nullable=False),
        sa.Column("document_id", sa.Uuid(), nullable=False),
        sa.Column("ocr_result_id", sa.Uuid(), nullable=False),
        sa.Column("fact_type", fact_type, nullable=False),
        sa.Column("fact_value", sa.Text(), nullable=False),
        sa.Column("normalized_value", sa.Text(), nullable=False),
        sa.Column("confidence", sa.Numeric(5, 4), nullable=False),
        sa.Column("page_number", sa.Integer(), nullable=True),
        sa.Column("source_bbox", sa.JSON(), nullable=True),
        sa.Column("source_text", sa.String(500), nullable=True),
        sa.Column("extractor_provider", sa.String(100), nullable=False),
        sa.Column("extractor_model", sa.String(100), nullable=False),
        sa.Column("prompt_version", sa.String(100), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["claim_id"], ["claims.claim_id"]),
        sa.ForeignKeyConstraint(["document_id"], ["medical_documents.document_id"]),
        sa.ForeignKeyConstraint(["ocr_result_id"], ["ocr_results.ocr_result_id"]),
        sa.PrimaryKeyConstraint("extracted_fact_id"),
    )
    for columns, name in (
        (["claim_id"], "ix_extracted_facts_claim_id"),
        (["document_id"], "ix_extracted_facts_document_id"),
        (["ocr_result_id"], "ix_extracted_facts_ocr_result_id"),
        (["claim_id", "fact_type"], "ix_extracted_facts_claim_type"),
    ):
        op.create_index(name, "extracted_facts", columns)
    op.create_table(
        "verified_facts",
        sa.Column("verified_fact_id", sa.Uuid(), nullable=False),
        sa.Column("claim_id", sa.Uuid(), nullable=False),
        sa.Column("extracted_fact_id", sa.Uuid(), nullable=False),
        sa.Column("fact_type", fact_type, nullable=False),
        sa.Column("verified_value", sa.Text(), nullable=False),
        sa.Column(
            "verification_status",
            sa.Enum(
                "AI_ONLY",
                "USER_CONFIRMED",
                "USER_MODIFIED",
                "EXPERT_CONFIRMED",
                "EXPERT_MODIFIED",
                "REJECTED",
                name="verificationstatus",
            ),
            nullable=False,
        ),
        sa.Column("verified_by", sa.Uuid(), nullable=False),
        sa.Column("verified_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("modification_reason", sa.String(100), nullable=True),
        sa.Column("source_document_id", sa.Uuid(), nullable=False),
        sa.Column("source_page", sa.Integer(), nullable=True),
        sa.Column("source_bbox", sa.JSON(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["claim_id"], ["claims.claim_id"]),
        sa.ForeignKeyConstraint(["extracted_fact_id"], ["extracted_facts.extracted_fact_id"]),
        sa.ForeignKeyConstraint(["verified_by"], ["users.user_id"]),
        sa.ForeignKeyConstraint(["source_document_id"], ["medical_documents.document_id"]),
        sa.PrimaryKeyConstraint("verified_fact_id"),
        sa.UniqueConstraint("extracted_fact_id"),
    )
    for columns, name in (
        (["claim_id"], "ix_verified_facts_claim_id"),
        (["extracted_fact_id"], "ix_verified_facts_extracted_fact_id"),
        (["claim_id", "fact_type"], "ix_verified_facts_claim_type"),
    ):
        op.create_index(name, "verified_facts", columns)


def downgrade() -> None:
    op.drop_table("verified_facts")
    op.drop_table("extracted_facts")
    op.drop_table("ocr_results")
    if op.get_bind().dialect.name == "postgresql":
        for name in ("verificationstatus", "facttype", "ocrstatus"):
            op.execute(f"DROP TYPE IF EXISTS {name}")
