"""add human reviews

Revision ID: b86d0f52ae31
Revises: a75c9e41fd20
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "b86d0f52ae31"
down_revision: str | None = "a75c9e41fd20"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    if op.get_bind().dialect.name == "postgresql":
        for value in (
            "REVIEW_CREATE",
            "REVIEW_ASSIGN",
            "REVIEW_ACCEPT",
            "REVIEW_APPROVE",
            "REVIEW_MODIFY",
            "REVIEW_DOCUMENT_REQUEST",
            "REVIEW_UNDETERMINED",
            "REVIEW_COMPLETE",
        ):
            op.execute(f"ALTER TYPE auditeventtype ADD VALUE IF NOT EXISTS '{value}'")
    review_type = sa.Enum(
        "FACT_REVIEW",
        "POLICY_REVIEW",
        "RULE_REVIEW",
        "ELIGIBILITY_REVIEW",
        "EXCLUSION_REVIEW",
        "CALCULATION_REVIEW",
        "GENERAL_CLAIM_REVIEW",
        name="reviewtype",
    )
    review_status = sa.Enum(
        "REQUESTED",
        "ASSIGNED",
        "IN_PROGRESS",
        "ADDITIONAL_DOCUMENT_REQUIRED",
        "APPROVED",
        "MODIFIED",
        "UNDETERMINED",
        "COMPLETED",
        name="reviewstatus",
    )
    request_status = sa.Enum(
        "REQUESTED", "SUBMITTED", "CANCELLED", "RESOLVED", name="documentrequeststatus"
    )
    op.create_table(
        "reviews",
        sa.Column("review_id", sa.Uuid(), primary_key=True),
        sa.Column("claim_id", sa.Uuid(), sa.ForeignKey("claims.claim_id"), nullable=False),
        sa.Column("assessment_id", sa.Uuid(), sa.ForeignKey("coverage_assessments.assessment_id")),
        sa.Column("reviewer_user_id", sa.Uuid(), sa.ForeignKey("users.user_id")),
        sa.Column("review_type", review_type, nullable=False),
        sa.Column("review_status", review_status, nullable=False),
        sa.Column("reason", sa.Text(), nullable=False),
        sa.Column("opinion", sa.Text()),
        sa.Column("previous_result", sa.JSON(), nullable=False),
        sa.Column("final_result", sa.JSON()),
        sa.Column("requested_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("started_at", sa.DateTime(timezone=True)),
        sa.Column("completed_at", sa.DateTime(timezone=True)),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
    )
    for cols, name in (
        (["claim_id"], "ix_reviews_claim_id"),
        (["assessment_id"], "ix_reviews_assessment_id"),
        (["reviewer_user_id"], "ix_reviews_reviewer_user_id"),
        (["review_type"], "ix_reviews_review_type"),
        (["review_status"], "ix_reviews_review_status"),
        (["review_status", "requested_at"], "ix_reviews_queue"),
    ):
        op.create_index(name, "reviews", cols)
    op.create_table(
        "review_assignments",
        sa.Column("assignment_id", sa.Uuid(), primary_key=True),
        sa.Column("review_id", sa.Uuid(), sa.ForeignKey("reviews.review_id"), nullable=False),
        sa.Column("reviewer_user_id", sa.Uuid(), sa.ForeignKey("users.user_id"), nullable=False),
        sa.Column("assigned_by", sa.Uuid(), sa.ForeignKey("users.user_id"), nullable=False),
        sa.Column("assigned_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("accepted_at", sa.DateTime(timezone=True)),
        sa.UniqueConstraint("review_id", name="uq_review_active_assignment"),
    )
    op.create_index("ix_review_assignments_review_id", "review_assignments", ["review_id"])
    op.create_index(
        "ix_review_assignments_reviewer_user_id", "review_assignments", ["reviewer_user_id"]
    )
    op.create_table(
        "additional_document_requests",
        sa.Column("request_id", sa.Uuid(), primary_key=True),
        sa.Column("review_id", sa.Uuid(), sa.ForeignKey("reviews.review_id"), nullable=False),
        sa.Column("claim_id", sa.Uuid(), sa.ForeignKey("claims.claim_id"), nullable=False),
        sa.Column("requested_document_type", sa.String(100)),
        sa.Column("requested_fact_type", sa.String(100)),
        sa.Column("reason", sa.Text(), nullable=False),
        sa.Column("user_message", sa.Text(), nullable=False),
        sa.Column("internal_note", sa.Text()),
        sa.Column("request_status", request_status, nullable=False),
        sa.Column("requested_by", sa.Uuid(), sa.ForeignKey("users.user_id"), nullable=False),
        sa.Column("requested_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("fulfilled_at", sa.DateTime(timezone=True)),
    )
    op.create_index(
        "ix_additional_document_requests_review_id", "additional_document_requests", ["review_id"]
    )
    op.create_index(
        "ix_additional_document_requests_claim_id", "additional_document_requests", ["claim_id"]
    )
    op.create_index(
        "ix_additional_document_requests_request_status",
        "additional_document_requests",
        ["request_status"],
    )


def downgrade() -> None:
    op.drop_table("additional_document_requests")
    op.drop_table("review_assignments")
    op.drop_table("reviews")
    if op.get_bind().dialect.name == "postgresql":
        op.execute("DROP TYPE IF EXISTS documentrequeststatus")
        op.execute("DROP TYPE IF EXISTS reviewstatus")
        op.execute("DROP TYPE IF EXISTS reviewtype")
