import enum
import uuid
from datetime import datetime

from sqlalchemy import BigInteger, DateTime, Enum, ForeignKey, Index, Integer, String
from sqlalchemy.orm import Mapped, mapped_column

from domain.user.models import utc_now
from infrastructure.database.base import Base


class DocumentType(enum.StrEnum):
    DIAGNOSIS_CERTIFICATE = "DIAGNOSIS_CERTIFICATE"
    SURGERY_CERTIFICATE = "SURGERY_CERTIFICATE"
    HOSPITALIZATION_CERTIFICATE = "HOSPITALIZATION_CERTIFICATE"
    MEDICAL_RECEIPT = "MEDICAL_RECEIPT"
    MEDICAL_DETAIL = "MEDICAL_DETAIL"
    INSURANCE_POLICY = "INSURANCE_POLICY"
    ACCIDENT_REPORT = "ACCIDENT_REPORT"
    OTHER = "OTHER"


class DocumentTypeSource(enum.StrEnum):
    USER = "USER"
    AI = "AI"
    REVIEWER = "REVIEWER"


class DocumentProcessingStatus(enum.StrEnum):
    UPLOADING = "UPLOADING"
    UPLOADED = "UPLOADED"
    VALIDATING = "VALIDATING"
    SCANNING = "SCANNING"
    READY = "READY"
    PROCESSING = "PROCESSING"
    COMPLETED = "COMPLETED"
    REJECTED = "REJECTED"
    FAILED = "FAILED"
    DELETED = "DELETED"


class MalwareScanStatus(enum.StrEnum):
    NOT_SCANNED = "NOT_SCANNED"
    SCANNING = "SCANNING"
    CLEAN = "CLEAN"
    INFECTED = "INFECTED"
    SCAN_FAILED = "SCAN_FAILED"


class MedicalDocument(Base):
    __tablename__ = "medical_documents"
    __table_args__ = (
        Index("ix_medical_documents_claim_hash", "claim_id", "file_hash"),
        Index("ix_medical_documents_uploaded_at", "uploaded_at"),
    )

    document_id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    additional_document_request_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("additional_document_requests.request_id"), index=True
    )
    submission_round: Mapped[int | None] = mapped_column(Integer)
    claim_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("claims.claim_id"), index=True)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.user_id"), index=True)
    document_type: Mapped[DocumentType] = mapped_column(Enum(DocumentType))
    document_type_source: Mapped[DocumentTypeSource] = mapped_column(
        Enum(DocumentTypeSource), default=DocumentTypeSource.USER
    )
    original_filename: Mapped[str] = mapped_column(String(255))
    storage_key: Mapped[str] = mapped_column(String(500), unique=True)
    file_hash: Mapped[str] = mapped_column(String(64), index=True)
    mime_type: Mapped[str] = mapped_column(String(100))
    file_size: Mapped[int] = mapped_column(BigInteger)
    page_count: Mapped[int | None] = mapped_column(Integer)
    malware_scan_status: Mapped[MalwareScanStatus] = mapped_column(
        Enum(MalwareScanStatus), index=True
    )
    processing_status: Mapped[DocumentProcessingStatus] = mapped_column(
        Enum(DocumentProcessingStatus), index=True
    )
    uploaded_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utc_now, onupdate=utc_now
    )
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
