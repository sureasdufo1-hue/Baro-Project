import re
from datetime import UTC, datetime
from typing import Any
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.orm import Session

from domain.claim.models import ClaimStatus
from domain.claim.service import ClaimStateMachine, owned_claim
from domain.document.models import (
    DocumentProcessingStatus,
    MalwareScanStatus,
    MedicalDocument,
)
from domain.fact.models import (
    ExtractedFact,
    FactType,
    OCRResult,
    OCRStatus,
    VerificationStatus,
    VerifiedFact,
)
from infrastructure.ai.provider import StructuredExtractionProvider
from infrastructure.ocr.provider import OCRProvider
from infrastructure.storage.object_storage import ObjectStorage
from shared.errors import DomainError


def normalize_value(fact_type: FactType, value: str) -> str:
    normalized = " ".join(value.strip().split())
    if fact_type is FactType.DIAGNOSIS_CODE:
        return normalized.upper().replace(" ", "")
    if fact_type.value.endswith("_DATE"):
        match = re.fullmatch(
            r"(\d{4})\s*[.\-/]\s*(\d{1,2})\s*[.\-/]\s*(\d{1,2})\.?",
            normalized,
        )
        if match:
            year, month, day = (int(item) for item in match.groups())
            return f"{year:04d}-{month:02d}-{day:02d}"
    return normalized


def queue_ocr(db: Session, document: MedicalDocument, provider: OCRProvider) -> OCRResult:
    if document.processing_status is not DocumentProcessingStatus.READY:
        raise DomainError("DOCUMENT_NOT_READY", "Only READY documents can be analyzed", 409)
    if document.malware_scan_status is not MalwareScanStatus.CLEAN:
        raise DomainError("DOCUMENT_NOT_READY", "Document safety scan is not clean", 409)
    duplicate = db.scalar(
        select(OCRResult).where(
            OCRResult.document_id == document.document_id,
            OCRResult.status.in_([OCRStatus.QUEUED, OCRStatus.PROCESSING, OCRStatus.RETRYING]),
        )
    )
    if duplicate:
        raise DomainError("OCR_ALREADY_RUNNING", "OCR is already running", 409)
    result = OCRResult(
        document_id=document.document_id,
        provider=provider.provider_name,
        model_name=provider.model_name,
        model_version=provider.model_version,
        status=OCRStatus.QUEUED,
        attempt_count=0,
    )
    db.add(result)
    db.flush()
    return result


def process_ocr(
    db: Session,
    result: OCRResult,
    storage: ObjectStorage,
    ocr: OCRProvider,
    extractor: StructuredExtractionProvider,
) -> list[ExtractedFact]:
    document = db.get(MedicalDocument, result.document_id)
    if (
        document is None
        or document.processing_status
        not in {DocumentProcessingStatus.READY, DocumentProcessingStatus.PROCESSING}
        or document.malware_scan_status is not MalwareScanStatus.CLEAN
    ):
        raise DomainError("DOCUMENT_NOT_READY", "Document is not eligible for OCR", 409)
    result.status = OCRStatus.PROCESSING
    result.attempt_count += 1
    result.processing_started_at = datetime.now(UTC)
    document.processing_status = DocumentProcessingStatus.PROCESSING
    db.flush()
    canonical = ocr.extract(storage.get_object(document.storage_key), document.mime_type)
    structured = extractor.extract_facts(canonical.text)
    facts = [
        ExtractedFact(
            claim_id=document.claim_id,
            document_id=document.document_id,
            ocr_result_id=result.ocr_result_id,
            fact_type=item.fact_type,
            fact_value=item.value,
            normalized_value=normalize_value(item.fact_type, item.value),
            confidence=item.confidence,
            page_number=item.page,
            source_bbox=item.source_bbox,
            source_text=item.source_text,
            extractor_provider=extractor.provider_name,
            extractor_model=f"{extractor.model_name}:{extractor.model_version}",
            prompt_version=extractor.prompt_version,
        )
        for item in structured.facts
    ]
    db.add_all(facts)
    result.raw_text = canonical.text
    result.raw_result = {"pages": canonical.pages}
    result.confidence = canonical.confidence
    result.status = OCRStatus.SUCCEEDED
    result.processing_completed_at = datetime.now(UTC)
    document.processing_status = DocumentProcessingStatus.COMPLETED
    claim = owned_claim(db, document.claim_id, document.user_id)
    if claim.status is ClaimStatus.DOCUMENT_PROCESSING:
        ClaimStateMachine.transition(claim, ClaimStatus.USER_VERIFICATION)
    db.flush()
    return facts


def mark_ocr_failure(result: OCRResult, document: MedicalDocument, code: str) -> None:
    result.status = OCRStatus.FAILED
    result.error_code = code
    result.processing_completed_at = datetime.now(UTC)
    document.processing_status = DocumentProcessingStatus.FAILED


def owned_extracted_fact(db: Session, fact_id: UUID, user_id: UUID) -> ExtractedFact:
    fact = db.get(ExtractedFact, fact_id)
    if fact is None:
        raise DomainError("FACT_NOT_FOUND", "Fact was not found", 404)
    owned_claim(db, fact.claim_id, user_id)
    return fact


def _verify(
    db: Session,
    fact: ExtractedFact,
    user_id: UUID,
    status: VerificationStatus,
    value: str,
    reason: str | None,
) -> VerifiedFact:
    existing = db.scalar(
        select(VerifiedFact).where(VerifiedFact.extracted_fact_id == fact.extracted_fact_id)
    )
    if existing:
        raise DomainError("FACT_ALREADY_VERIFIED", "Fact already has a verification decision", 409)
    verified = VerifiedFact(
        claim_id=fact.claim_id,
        extracted_fact_id=fact.extracted_fact_id,
        fact_type=fact.fact_type,
        verified_value=normalize_value(fact.fact_type, value),
        verification_status=status,
        verified_by=user_id,
        verified_at=datetime.now(UTC),
        modification_reason=reason,
        source_document_id=fact.document_id,
        source_page=fact.page_number,
        source_bbox=fact.source_bbox,
    )
    db.add(verified)
    db.flush()
    return verified


def confirm_fact(db: Session, fact: ExtractedFact, user_id: UUID) -> VerifiedFact:
    return _verify(
        db, fact, user_id, VerificationStatus.USER_CONFIRMED, fact.normalized_value, None
    )


def modify_fact(
    db: Session, fact: ExtractedFact, user_id: UUID, value: str, reason: str
) -> VerifiedFact:
    if not value.strip() or not reason.strip():
        raise DomainError("INVALID_FACT_MODIFICATION", "Value and reason are required", 422)
    return _verify(db, fact, user_id, VerificationStatus.USER_MODIFIED, value, reason)


def reject_fact(
    db: Session, fact: ExtractedFact, user_id: UUID, reason: str | None
) -> VerifiedFact:
    return _verify(db, fact, user_id, VerificationStatus.REJECTED, fact.normalized_value, reason)


def fact_view(db: Session, fact: ExtractedFact) -> dict[str, Any]:
    verified = db.scalar(
        select(VerifiedFact).where(VerifiedFact.extracted_fact_id == fact.extracted_fact_id)
    )
    return {
        "extracted_fact_id": fact.extracted_fact_id,
        "claim_id": fact.claim_id,
        "document_id": fact.document_id,
        "ocr_result_id": fact.ocr_result_id,
        "fact_type": fact.fact_type,
        "fact_value": fact.fact_value,
        "normalized_value": fact.normalized_value,
        "confidence": fact.confidence,
        "page_number": fact.page_number,
        "source_bbox": fact.source_bbox,
        "source_text": fact.source_text,
        "verification": None
        if verified is None
        else {
            "verified_fact_id": verified.verified_fact_id,
            "verified_value": verified.verified_value,
            "verification_status": verified.verification_status,
            "modification_reason": verified.modification_reason,
        },
    }
