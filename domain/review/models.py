import enum
import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import (
    JSON,
    DateTime,
    Enum,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.orm import Mapped, mapped_column

from domain.user.models import utc_now
from infrastructure.database.base import Base


class ReviewType(enum.StrEnum):
    FACT_REVIEW = "FACT_REVIEW"
    POLICY_REVIEW = "POLICY_REVIEW"
    RULE_REVIEW = "RULE_REVIEW"
    ELIGIBILITY_REVIEW = "ELIGIBILITY_REVIEW"
    EXCLUSION_REVIEW = "EXCLUSION_REVIEW"
    CALCULATION_REVIEW = "CALCULATION_REVIEW"
    GENERAL_CLAIM_REVIEW = "GENERAL_CLAIM_REVIEW"


class ReviewStatus(enum.StrEnum):
    REQUESTED = "REQUESTED"
    ASSIGNED = "ASSIGNED"
    IN_PROGRESS = "IN_PROGRESS"
    ADDITIONAL_DOCUMENT_REQUIRED = "ADDITIONAL_DOCUMENT_REQUIRED"
    APPROVED = "APPROVED"
    MODIFIED = "MODIFIED"
    UNDETERMINED = "UNDETERMINED"
    COMPLETED = "COMPLETED"


class DocumentRequestStatus(enum.StrEnum):
    REQUESTED = "REQUESTED"
    SUBMITTED = "SUBMITTED"
    CANCELLED = "CANCELLED"
    RESOLVED = "RESOLVED"


class Review(Base):
    __tablename__ = "reviews"
    __table_args__ = (Index("ix_reviews_queue", "review_status", "requested_at"),)
    review_id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    revision: Mapped[int] = mapped_column(Integer, default=1, nullable=False)
    claim_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("claims.claim_id"), index=True)
    assessment_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("coverage_assessments.assessment_id"), index=True
    )
    reviewer_user_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.user_id"), index=True
    )
    review_type: Mapped[ReviewType] = mapped_column(Enum(ReviewType), index=True)
    review_status: Mapped[ReviewStatus] = mapped_column(Enum(ReviewStatus), index=True)
    reason: Mapped[str] = mapped_column(Text)
    opinion: Mapped[str | None] = mapped_column(Text)
    previous_result: Mapped[dict[str, Any]] = mapped_column(JSON, default=dict)
    final_result: Mapped[dict[str, Any] | None] = mapped_column(JSON)
    requested_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    started_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utc_now, onupdate=utc_now
    )
    __mapper_args__ = {"version_id_col": revision}


class ReviewAssignment(Base):
    __tablename__ = "review_assignments"
    __table_args__ = (UniqueConstraint("review_id", name="uq_review_active_assignment"),)
    assignment_id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    review_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("reviews.review_id"), index=True)
    reviewer_user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.user_id"), index=True)
    assigned_by: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.user_id"))
    assigned_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    accepted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class AdditionalDocumentRequest(Base):
    __tablename__ = "additional_document_requests"
    request_id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    submission_round: Mapped[int] = mapped_column(Integer, nullable=False)
    review_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("reviews.review_id"), index=True)
    claim_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("claims.claim_id"), index=True)
    requested_document_type: Mapped[str | None] = mapped_column(String(100))
    requested_fact_type: Mapped[str | None] = mapped_column(String(100))
    reason: Mapped[str] = mapped_column(Text)
    user_message: Mapped[str] = mapped_column(Text)
    internal_note: Mapped[str | None] = mapped_column(Text)
    request_status: Mapped[DocumentRequestStatus] = mapped_column(
        Enum(DocumentRequestStatus), default=DocumentRequestStatus.REQUESTED, index=True
    )
    requested_by: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.user_id"))
    requested_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    fulfilled_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
