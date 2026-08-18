import hashlib
import re
from datetime import UTC, datetime
from pathlib import PurePath
from typing import Any
from uuid import UUID, uuid4

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from domain.claim.models import Claim, ClaimStatus
from domain.claim.service import owned_claim
from domain.document.models import (
    DocumentProcessingStatus,
    DocumentType,
    DocumentTypeSource,
    MalwareScanStatus,
    MedicalDocument,
)
from infrastructure.security.malware import MalwareScanner, ScanResult
from infrastructure.storage.object_storage import ObjectStorage
from shared.errors import DomainError

ALLOWED_FORMATS = {
    ".pdf": "application/pdf",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".png": "image/png",
    ".heic": "image/heic",
}
UPLOADABLE_CLAIM_STATUSES = frozenset({ClaimStatus.DRAFT, ClaimStatus.DOCUMENT_REQUIRED})


def safe_filename(filename: str | None) -> str:
    name = PurePath((filename or "document").replace("\\", "/")).name
    name = re.sub(r"[\x00-\x1f<>:\"/\\|?*]", "_", name).strip(" .")
    return (name or "document")[:255]


def detected_mime(content: bytes) -> str | None:
    if content.startswith(b"%PDF-"):
        return "application/pdf"
    if content.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if content.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if (
        len(content) >= 12
        and content[4:8] == b"ftyp"
        and content[8:12] in {b"heic", b"heix", b"hevc", b"hevx", b"mif1", b"msf1"}
    ):
        return "image/heic"
    return None


def validate_file(
    filename: str | None, client_mime: str | None, content: bytes, maximum: int
) -> str:
    if not content:
        raise DomainError("INVALID_FILE_SIGNATURE", "The uploaded file is empty", 422)
    if len(content) > maximum:
        raise DomainError("FILE_TOO_LARGE", "The document exceeds the size limit", 413)
    extension = PurePath(filename or "").suffix.lower()
    expected = ALLOWED_FORMATS.get(extension)
    if expected is None:
        raise DomainError("UNSUPPORTED_FILE_FORMAT", "Unsupported file extension", 422)
    actual = detected_mime(content)
    if actual is None or actual != expected:
        raise DomainError("INVALID_FILE_SIGNATURE", "File signature does not match its type", 422)
    normalized_client = "image/jpeg" if client_mime == "image/jpg" else client_mime
    if normalized_client != actual:
        raise DomainError("UNSUPPORTED_FILE_FORMAT", "Declared MIME type does not match", 422)
    return actual


def ensure_upload_allowed(claim: Claim) -> None:
    if claim.status not in UPLOADABLE_CLAIM_STATUSES:
        raise DomainError("DOCUMENT_UPLOAD_NOT_ALLOWED", "Claim does not accept documents", 409)


def create_document(
    db: Session,
    storage: ObjectStorage,
    scanner: MalwareScanner,
    user_id: UUID,
    claim_id: UUID,
    document_type: DocumentType,
    filename: str | None,
    client_mime: str | None,
    content: bytes,
    maximum_size: int,
    maximum_documents: int,
    maximum_total_size: int,
) -> MedicalDocument:
    claim = owned_claim(db, claim_id, user_id)
    ensure_upload_allowed(claim)
    active_filter = MedicalDocument.processing_status != DocumentProcessingStatus.DELETED
    count, total = db.execute(
        select(func.count(), func.coalesce(func.sum(MedicalDocument.file_size), 0)).where(
            MedicalDocument.claim_id == claim_id, active_filter
        )
    ).one()
    if count >= maximum_documents:
        raise DomainError("DOCUMENT_LIMIT_EXCEEDED", "Document count limit exceeded", 409)
    mime = validate_file(filename, client_mime, content, maximum_size)
    if int(total) + len(content) > maximum_total_size:
        raise DomainError("CLAIM_STORAGE_LIMIT_EXCEEDED", "Claim storage limit exceeded", 413)
    digest = hashlib.sha256(content).hexdigest()
    duplicate = db.scalar(
        select(MedicalDocument).where(
            MedicalDocument.claim_id == claim_id, MedicalDocument.file_hash == digest, active_filter
        )
    )
    if duplicate:
        raise DomainError("DUPLICATE_DOCUMENT", "This file is already registered", 409)
    scan_result = scanner.scan(content)
    if scan_result is ScanResult.INFECTED:
        raise DomainError("MALWARE_DETECTED", "The file was rejected for safety", 422)
    if scan_result is ScanResult.SCAN_FAILED:
        raise DomainError("MALWARE_SCAN_FAILED", "The file safety scan failed", 503)
    document_id = uuid4()
    key = f"claims/{claim.claim_id}/documents/{document_id}"
    storage.put_object(key, content)
    document = MedicalDocument(
        document_id=document_id,
        claim_id=claim.claim_id,
        user_id=user_id,
        document_type=document_type,
        document_type_source=DocumentTypeSource.USER,
        original_filename=safe_filename(filename),
        storage_key=key,
        file_hash=digest,
        mime_type=mime,
        file_size=len(content),
        page_count=None,
        malware_scan_status=MalwareScanStatus.CLEAN,
        processing_status=DocumentProcessingStatus.READY,
    )
    db.add(document)
    try:
        db.flush()
    except Exception:
        storage.delete_object(key)
        raise
    return document


def owned_document(db: Session, document_id: UUID, user_id: UUID) -> MedicalDocument:
    document = db.get(MedicalDocument, document_id)
    if document is None:
        raise DomainError("DOCUMENT_NOT_FOUND", "Document was not found", 404)
    owned_claim(db, document.claim_id, user_id)
    return document


def list_documents(db: Session, claim_id: UUID, user_id: UUID) -> list[MedicalDocument]:
    owned_claim(db, claim_id, user_id)
    return list(
        db.scalars(
            select(MedicalDocument)
            .where(
                MedicalDocument.claim_id == claim_id,
                MedicalDocument.processing_status != DocumentProcessingStatus.DELETED,
            )
            .order_by(MedicalDocument.uploaded_at.desc())
        )
    )


def delete_document(document: MedicalDocument, storage: ObjectStorage) -> None:
    if document.processing_status in {
        DocumentProcessingStatus.PROCESSING,
        DocumentProcessingStatus.COMPLETED,
    }:
        raise DomainError("INVALID_DOCUMENT_STATE", "Processed documents cannot be deleted", 409)
    storage.delete_object(document.storage_key)
    document.processing_status = DocumentProcessingStatus.DELETED
    document.deleted_at = datetime.now(UTC)


def document_view(document: MedicalDocument) -> dict[str, Any]:
    return {
        "document_id": document.document_id,
        "additional_document_request_id": document.additional_document_request_id,
        "submission_round": document.submission_round,
        "claim_id": document.claim_id,
        "document_type": document.document_type,
        "document_type_source": document.document_type_source,
        "original_filename": document.original_filename,
        "file_hash": document.file_hash,
        "mime_type": document.mime_type,
        "file_size": document.file_size,
        "page_count": document.page_count,
        "malware_scan_status": document.malware_scan_status,
        "processing_status": document.processing_status,
        "uploaded_at": document.uploaded_at,
        "updated_at": document.updated_at,
    }
