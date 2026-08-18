"""add medical documents

Revision ID: b71e2a9f4c30
Revises: 8d9c4b21a7ef
Create Date: 2026-08-18
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "b71e2a9f4c30"
down_revision: str | None = "8d9c4b21a7ef"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    if op.get_bind().dialect.name == "postgresql":
        for value in (
            "DOCUMENT_UPLOAD",
            "DOCUMENT_VIEW",
            "DOCUMENT_DOWNLOAD",
            "DOCUMENT_DELETE",
            "DOCUMENT_TYPE_MODIFY",
            "DOCUMENT_SCAN_STARTED",
            "DOCUMENT_SCAN_COMPLETED",
            "DOCUMENT_SCAN_REJECTED",
        ):
            op.execute(f"ALTER TYPE auditeventtype ADD VALUE IF NOT EXISTS '{value}'")
    op.create_table(
        "medical_documents",
        sa.Column("document_id", sa.Uuid(), nullable=False),
        sa.Column("claim_id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column(
            "document_type",
            sa.Enum(
                "DIAGNOSIS_CERTIFICATE",
                "SURGERY_CERTIFICATE",
                "HOSPITALIZATION_CERTIFICATE",
                "MEDICAL_RECEIPT",
                "MEDICAL_DETAIL",
                "INSURANCE_POLICY",
                "ACCIDENT_REPORT",
                "OTHER",
                name="documenttype",
            ),
            nullable=False,
        ),
        sa.Column(
            "document_type_source",
            sa.Enum("USER", "AI", "REVIEWER", name="documenttypesource"),
            nullable=False,
        ),
        sa.Column("original_filename", sa.String(length=255), nullable=False),
        sa.Column("storage_key", sa.String(length=500), nullable=False),
        sa.Column("file_hash", sa.String(length=64), nullable=False),
        sa.Column("mime_type", sa.String(length=100), nullable=False),
        sa.Column("file_size", sa.BigInteger(), nullable=False),
        sa.Column("page_count", sa.Integer(), nullable=True),
        sa.Column(
            "malware_scan_status",
            sa.Enum(
                "NOT_SCANNED",
                "SCANNING",
                "CLEAN",
                "INFECTED",
                "SCAN_FAILED",
                name="malwarescanstatus",
            ),
            nullable=False,
        ),
        sa.Column(
            "processing_status",
            sa.Enum(
                "UPLOADING",
                "UPLOADED",
                "VALIDATING",
                "SCANNING",
                "READY",
                "PROCESSING",
                "COMPLETED",
                "REJECTED",
                "FAILED",
                "DELETED",
                name="documentprocessingstatus",
            ),
            nullable=False,
        ),
        sa.Column("uploaded_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(["claim_id"], ["claims.claim_id"]),
        sa.ForeignKeyConstraint(["user_id"], ["users.user_id"]),
        sa.PrimaryKeyConstraint("document_id"),
        sa.UniqueConstraint("storage_key"),
    )
    for columns, name in (
        (["claim_id"], "ix_medical_documents_claim_id"),
        (["user_id"], "ix_medical_documents_user_id"),
        (["file_hash"], "ix_medical_documents_file_hash"),
        (["malware_scan_status"], "ix_medical_documents_malware_scan_status"),
        (["processing_status"], "ix_medical_documents_processing_status"),
        (["uploaded_at"], "ix_medical_documents_uploaded_at"),
        (["claim_id", "file_hash"], "ix_medical_documents_claim_hash"),
    ):
        op.create_index(name, "medical_documents", columns)


def downgrade() -> None:
    for name in (
        "ix_medical_documents_claim_hash",
        "ix_medical_documents_uploaded_at",
        "ix_medical_documents_processing_status",
        "ix_medical_documents_malware_scan_status",
        "ix_medical_documents_file_hash",
        "ix_medical_documents_user_id",
        "ix_medical_documents_claim_id",
    ):
        op.drop_index(name, table_name="medical_documents")
    op.drop_table("medical_documents")
    if op.get_bind().dialect.name == "postgresql":
        for enum_name in (
            "documentprocessingstatus",
            "malwarescanstatus",
            "documenttypesource",
            "documenttype",
        ):
            op.execute(f"DROP TYPE IF EXISTS {enum_name}")
