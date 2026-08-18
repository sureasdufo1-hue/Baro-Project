import enum
import uuid
from datetime import date, datetime

from sqlalchemy import Date, DateTime, Enum, ForeignKey, Index, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from domain.user.models import utc_now
from infrastructure.database.base import Base


class ClaimType(enum.StrEnum):
    DISEASE = "DISEASE"
    INJURY = "INJURY"
    OTHER = "OTHER"


class ClaimStatus(enum.StrEnum):
    DRAFT = "DRAFT"
    DOCUMENT_REQUIRED = "DOCUMENT_REQUIRED"
    DOCUMENT_PROCESSING = "DOCUMENT_PROCESSING"
    USER_VERIFICATION = "USER_VERIFICATION"
    ASSESSING = "ASSESSING"
    MANUAL_REVIEW = "MANUAL_REVIEW"
    COMPLETED = "COMPLETED"
    FAILED = "FAILED"
    CANCELLED = "CANCELLED"
    CLOSED = "CLOSED"


class Claim(Base):
    __tablename__ = "claims"
    __table_args__ = (
        Index("ix_claims_user_status", "user_id", "status"),
        Index("ix_claims_user_created_at", "user_id", "created_at"),
    )

    claim_id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.user_id"), index=True)
    insured_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("insureds.insured_id"), index=True)
    contract_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("insurance_contracts.contract_id"), index=True
    )
    claim_number: Mapped[str] = mapped_column(String(40), unique=True, index=True)
    claim_type: Mapped[ClaimType] = mapped_column(Enum(ClaimType), index=True)
    status: Mapped[ClaimStatus] = mapped_column(
        Enum(ClaimStatus), default=ClaimStatus.DRAFT, index=True
    )
    title: Mapped[str] = mapped_column(String(200))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utc_now, onupdate=utc_now
    )
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    accident: Mapped["Accident"] = relationship(
        back_populates="claim", cascade="all, delete-orphan", uselist=False
    )


class Accident(Base):
    __tablename__ = "accidents"
    __table_args__ = (UniqueConstraint("claim_id", name="uq_accidents_claim_id"),)

    accident_id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    claim_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("claims.claim_id"), index=True, unique=True
    )
    accident_type: Mapped[ClaimType] = mapped_column(Enum(ClaimType))
    accident_date: Mapped[date | None] = mapped_column(Date)
    diagnosis_date: Mapped[date | None] = mapped_column(Date)
    onset_date: Mapped[date | None] = mapped_column(Date)
    description: Mapped[str | None] = mapped_column(Text)
    location: Mapped[str | None] = mapped_column(String(300))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utc_now, onupdate=utc_now
    )
    claim: Mapped[Claim] = relationship(back_populates="accident")
