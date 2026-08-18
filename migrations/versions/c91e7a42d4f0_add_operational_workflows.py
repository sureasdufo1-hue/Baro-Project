"""add operational workflows and persistent sessions

Revision ID: c91e7a42d4f0
Revises: b86d0f52ae31
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "c91e7a42d4f0"
down_revision: str | None = "b86d0f52ae31"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    if op.get_bind().dialect.name == "postgresql":
        for value in ("REVIEW_DOCUMENT_SUBMITTED", "REVIEW_RESUMED", "SESSION_REVOKE"):
            op.execute(f"ALTER TYPE auditeventtype ADD VALUE IF NOT EXISTS '{value}'")
    op.create_table(
        "auth_sessions",
        sa.Column("session_id", sa.Uuid(), primary_key=True),
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.user_id"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_used_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("revoked_at", sa.DateTime(timezone=True)),
        sa.Column("source_ip", sa.String(45)),
        sa.Column("user_agent", sa.String(300)),
    )
    op.create_index("ix_auth_sessions_user_id", "auth_sessions", ["user_id"])
    op.create_index("ix_auth_sessions_expires_at", "auth_sessions", ["expires_at"])
    op.create_index("ix_auth_sessions_revoked_at", "auth_sessions", ["revoked_at"])
    op.add_column(
        "reviews", sa.Column("revision", sa.Integer(), nullable=False, server_default="1")
    )
    op.add_column(
        "additional_document_requests",
        sa.Column("submission_round", sa.Integer(), nullable=False, server_default="1"),
    )
    with op.batch_alter_table("medical_documents") as batch:
        batch.add_column(sa.Column("additional_document_request_id", sa.Uuid()))
        batch.add_column(sa.Column("submission_round", sa.Integer()))
        batch.create_foreign_key(
            "fk_medical_documents_additional_request",
            "additional_document_requests",
            ["additional_document_request_id"],
            ["request_id"],
        )
    op.create_index(
        "ix_medical_documents_additional_document_request_id",
        "medical_documents",
        ["additional_document_request_id"],
    )
    op.add_column(
        "evidences", sa.Column("evidence_version", sa.Integer(), nullable=False, server_default="1")
    )
    op.execute(
        "UPDATE evidences SET evidence_version = "
        "(SELECT calculation_version FROM benefit_calculations "
        "WHERE benefit_calculations.calculation_id = evidences.calculation_id)"
    )
    op.create_index("ix_evidences_evidence_version", "evidences", ["evidence_version"])


def downgrade() -> None:
    op.drop_index("ix_evidences_evidence_version", table_name="evidences")
    op.drop_column("evidences", "evidence_version")
    op.drop_index(
        "ix_medical_documents_additional_document_request_id", table_name="medical_documents"
    )
    with op.batch_alter_table("medical_documents") as batch:
        batch.drop_constraint("fk_medical_documents_additional_request", type_="foreignkey")
        batch.drop_column("submission_round")
        batch.drop_column("additional_document_request_id")
    op.drop_column("additional_document_requests", "submission_round")
    op.drop_column("reviews", "revision")
    op.drop_table("auth_sessions")
