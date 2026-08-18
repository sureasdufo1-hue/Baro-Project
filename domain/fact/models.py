import enum
import uuid
from datetime import datetime
from decimal import Decimal
from typing import Any

from sqlalchemy import JSON, DateTime, Enum, ForeignKey, Index, Numeric, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from domain.user.models import utc_now
from infrastructure.database.base import Base


class OCRStatus(enum.StrEnum):
    QUEUED = "QUEUED"
    PROCESSING = "PROCESSING"
    SUCCEEDED = "SUCCEEDED"
    FAILED = "FAILED"
    RETRYING = "RETRYING"
    CANCELLED = "CANCELLED"


class FactType(enum.StrEnum):
    DIAGNOSIS_NAME = "DIAGNOSIS_NAME"
    DIAGNOSIS_CODE = "DIAGNOSIS_CODE"
    DIAGNOSIS_DATE = "DIAGNOSIS_DATE"
    SURGERY_NAME = "SURGERY_NAME"
    SURGERY_DATE = "SURGERY_DATE"
    HOSPITAL_ADMISSION_DATE = "HOSPITAL_ADMISSION_DATE"
    HOSPITAL_DISCHARGE_DATE = "HOSPITAL_DISCHARGE_DATE"
    ACCIDENT_DATE = "ACCIDENT_DATE"
    MEDICAL_FACILITY = "MEDICAL_FACILITY"
    DOCUMENT_ISSUE_DATE = "DOCUMENT_ISSUE_DATE"


class VerificationStatus(enum.StrEnum):
    AI_ONLY = "AI_ONLY"
    USER_CONFIRMED = "USER_CONFIRMED"
    USER_MODIFIED = "USER_MODIFIED"
    EXPERT_CONFIRMED = "EXPERT_CONFIRMED"
    EXPERT_MODIFIED = "EXPERT_MODIFIED"
    REJECTED = "REJECTED"


class OCRResult(Base):
    __tablename__ = "ocr_results"
    ocr_result_id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    document_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("medical_documents.document_id"), index=True
    )
    provider: Mapped[str] = mapped_column(String(100))
    model_name: Mapped[str] = mapped_column(String(100))
    model_version: Mapped[str] = mapped_column(String(100))
    raw_text: Mapped[str | None] = mapped_column(Text)
    raw_result: Mapped[dict[str, Any] | None] = mapped_column(JSON)
    confidence: Mapped[Decimal | None] = mapped_column(Numeric(5, 4))
    status: Mapped[OCRStatus] = mapped_column(Enum(OCRStatus), index=True)
    attempt_count: Mapped[int] = mapped_column(default=0)
    error_code: Mapped[str | None] = mapped_column(String(100))
    processing_started_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    processing_completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)


class ExtractedFact(Base):
    __tablename__ = "extracted_facts"
    __table_args__ = (Index("ix_extracted_facts_claim_type", "claim_id", "fact_type"),)
    extracted_fact_id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    claim_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("claims.claim_id"), index=True)
    document_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("medical_documents.document_id"), index=True
    )
    ocr_result_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("ocr_results.ocr_result_id"), index=True
    )
    fact_type: Mapped[FactType] = mapped_column(Enum(FactType))
    fact_value: Mapped[str] = mapped_column(Text)
    normalized_value: Mapped[str] = mapped_column(Text)
    confidence: Mapped[Decimal] = mapped_column(Numeric(5, 4))
    page_number: Mapped[int | None]
    source_bbox: Mapped[dict[str, Any] | None] = mapped_column(JSON)
    source_text: Mapped[str | None] = mapped_column(String(500))
    extractor_provider: Mapped[str] = mapped_column(String(100))
    extractor_model: Mapped[str] = mapped_column(String(100))
    prompt_version: Mapped[str] = mapped_column(String(100))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)


class VerifiedFact(Base):
    __tablename__ = "verified_facts"
    __table_args__ = (Index("ix_verified_facts_claim_type", "claim_id", "fact_type"),)
    verified_fact_id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    claim_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("claims.claim_id"), index=True)
    extracted_fact_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("extracted_facts.extracted_fact_id"), index=True
    )
    fact_type: Mapped[FactType] = mapped_column(Enum(FactType))
    verified_value: Mapped[str] = mapped_column(Text)
    verification_status: Mapped[VerificationStatus] = mapped_column(Enum(VerificationStatus))
    verified_by: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.user_id"))
    verified_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    modification_reason: Mapped[str | None] = mapped_column(String(100))
    source_document_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("medical_documents.document_id")
    )
    source_page: Mapped[int | None]
    source_bbox: Mapped[dict[str, Any] | None] = mapped_column(JSON)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utc_now, onupdate=utc_now
    )
