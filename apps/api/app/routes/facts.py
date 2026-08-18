from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session

from apps.api.app.audit import record_audit
from apps.api.app.dependencies import (
    get_ocr_provider,
    get_ocr_queue,
    require_authenticated_user,
)
from domain.audit.models import AuditEventType, AuditResult
from domain.claim.models import ClaimStatus
from domain.claim.service import ClaimStateMachine, owned_claim
from domain.document.models import DocumentProcessingStatus, MedicalDocument
from domain.document.service import owned_document
from domain.fact.models import ExtractedFact, OCRResult, OCRStatus, VerifiedFact
from domain.fact.service import (
    confirm_fact,
    fact_view,
    modify_fact,
    owned_extracted_fact,
    queue_ocr,
    reject_fact,
)
from domain.user.models import User
from infrastructure.database.session import get_db
from infrastructure.ocr.provider import OCRProvider
from infrastructure.queue.ocr import OCRQueue
from shared.errors import DomainError

claim_router = APIRouter(prefix="/api/claims", tags=["facts"])
document_router = APIRouter(prefix="/api/documents", tags=["facts"])
fact_router = APIRouter(prefix="/api/facts", tags=["facts"])


class ModifyFactInput(BaseModel):
    value: str = Field(min_length=1, max_length=500)
    reason: str = Field(min_length=1, max_length=100)


class RejectFactInput(BaseModel):
    reason: str | None = Field(default=None, max_length=100)


def audit(
    db: Session,
    request: Request,
    user: User,
    event: AuditEventType,
    object_type: str,
    object_id: UUID,
    claim_id: UUID,
    before: dict[str, Any] | None = None,
    after: dict[str, Any] | None = None,
) -> None:
    record_audit(
        db,
        event_type=event,
        result=AuditResult.SUCCESS,
        actor_user_id=user.user_id,
        object_type=object_type,
        object_id=str(object_id),
        claim_id=claim_id,
        request_id=request.state.request_id,
        source_ip=request.client.host if request.client else None,
        before_value=before,
        after_value=after,
    )


def enqueue_result(
    db: Session,
    queue: OCRQueue,
    result: OCRResult,
    claim_id: UUID,
    request: Request,
    user: User,
) -> str:
    db.commit()
    try:
        job_id = queue.enqueue(result.ocr_result_id)
    except Exception as exc:
        result.status = OCRStatus.FAILED
        result.error_code = "OCR_QUEUE_ERROR"
        db.commit()
        raise DomainError("OCR_QUEUE_ERROR", "OCR job could not be queued", 503) from exc
    audit(
        db,
        request,
        user,
        AuditEventType.OCR_REQUEST,
        "OCRResult",
        result.ocr_result_id,
        claim_id,
        after={"job_id": job_id, "status": "QUEUED"},
    )
    db.commit()
    return job_id


@document_router.post("/{document_id}/ocr", status_code=202, response_model=None)
def request_document_ocr(
    document_id: UUID,
    request: Request,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
    provider: OCRProvider = Depends(get_ocr_provider),
    queue: OCRQueue = Depends(get_ocr_queue),
) -> dict[str, Any]:
    document = owned_document(db, document_id, user.user_id)
    claim = owned_claim(db, document.claim_id, user.user_id)
    if claim.status is ClaimStatus.DOCUMENT_REQUIRED:
        ClaimStateMachine.transition(claim, ClaimStatus.DOCUMENT_PROCESSING)
    elif claim.status is not ClaimStatus.DOCUMENT_PROCESSING:
        raise DomainError("INVALID_CLAIM_STATE", "Claim cannot start document analysis", 409)
    result = queue_ocr(db, document, provider)
    job_id = enqueue_result(db, queue, result, claim.claim_id, request, user)
    return {"ocr_result_id": result.ocr_result_id, "job_id": job_id, "status": result.status}


@claim_router.post("/{claim_id}/analysis", status_code=202, response_model=None)
def request_claim_analysis(
    claim_id: UUID,
    request: Request,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
    provider: OCRProvider = Depends(get_ocr_provider),
    queue: OCRQueue = Depends(get_ocr_queue),
) -> dict[str, Any]:
    claim = owned_claim(db, claim_id, user.user_id)
    if claim.status is not ClaimStatus.DOCUMENT_REQUIRED:
        raise DomainError("INVALID_CLAIM_STATE", "Claim is not ready for document analysis", 409)
    documents = list(
        db.scalars(
            select(MedicalDocument).where(
                MedicalDocument.claim_id == claim_id,
                MedicalDocument.processing_status == DocumentProcessingStatus.READY,
            )
        )
    )
    if not documents:
        raise DomainError("REQUIRED_DOCUMENT_MISSING", "No READY documents are available", 409)
    ClaimStateMachine.transition(claim, ClaimStatus.DOCUMENT_PROCESSING)
    results = [queue_ocr(db, document, provider) for document in documents]
    queued = [enqueue_result(db, queue, result, claim_id, request, user) for result in results]
    return {"claim_status": claim.status, "jobs": queued}


@claim_router.get("/{claim_id}/analysis-status", response_model=None)
def analysis_status(
    claim_id: UUID,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> dict[str, Any]:
    claim = owned_claim(db, claim_id, user.user_id)
    documents = list(
        db.scalars(select(MedicalDocument).where(MedicalDocument.claim_id == claim_id))
    )
    results = list(
        db.scalars(
            select(OCRResult)
            .join(MedicalDocument, OCRResult.document_id == MedicalDocument.document_id)
            .where(MedicalDocument.claim_id == claim_id)
            .order_by(OCRResult.created_at.desc())
        )
    )
    return {
        "claim_status": claim.status,
        "documents": [
            {"document_id": item.document_id, "processing_status": item.processing_status}
            for item in documents
        ],
        "ocr_results": [
            {
                "ocr_result_id": item.ocr_result_id,
                "document_id": item.document_id,
                "status": item.status,
                "attempt_count": item.attempt_count,
                "error_code": item.error_code,
            }
            for item in results
        ],
    }


@claim_router.get("/{claim_id}/facts", response_model=None)
def list_facts(
    claim_id: UUID,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> list[dict[str, Any]]:
    owned_claim(db, claim_id, user.user_id)
    facts = list(
        db.scalars(
            select(ExtractedFact)
            .where(ExtractedFact.claim_id == claim_id)
            .order_by(ExtractedFact.created_at)
        )
    )
    return [fact_view(db, fact) for fact in facts]


def verified_view(item: VerifiedFact) -> dict[str, Any]:
    return {
        "verified_fact_id": item.verified_fact_id,
        "extracted_fact_id": item.extracted_fact_id,
        "fact_type": item.fact_type,
        "verified_value": item.verified_value,
        "verification_status": item.verification_status,
        "modification_reason": item.modification_reason,
    }


@fact_router.post("/{fact_id}/confirm", response_model=None)
def confirm(
    fact_id: UUID,
    request: Request,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> dict[str, Any]:
    fact = owned_extracted_fact(db, fact_id, user.user_id)
    item = confirm_fact(db, fact, user.user_id)
    audit(
        db,
        request,
        user,
        AuditEventType.FACT_CONFIRM,
        "VerifiedFact",
        item.verified_fact_id,
        fact.claim_id,
        after={"status": item.verification_status.value},
    )
    db.commit()
    return verified_view(item)


@fact_router.post("/{fact_id}/modify", response_model=None)
def modify(
    fact_id: UUID,
    data: ModifyFactInput,
    request: Request,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> dict[str, Any]:
    fact = owned_extracted_fact(db, fact_id, user.user_id)
    item = modify_fact(db, fact, user.user_id, data.value, data.reason)
    audit(
        db,
        request,
        user,
        AuditEventType.FACT_MODIFY,
        "VerifiedFact",
        item.verified_fact_id,
        fact.claim_id,
        before={"value": fact.normalized_value},
        after={"value": item.verified_value, "reason": data.reason},
    )
    db.commit()
    return verified_view(item)


@fact_router.post("/{fact_id}/reject", response_model=None)
def reject(
    fact_id: UUID,
    data: RejectFactInput,
    request: Request,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> dict[str, Any]:
    fact = owned_extracted_fact(db, fact_id, user.user_id)
    item = reject_fact(db, fact, user.user_id, data.reason)
    audit(
        db,
        request,
        user,
        AuditEventType.FACT_REJECT,
        "VerifiedFact",
        item.verified_fact_id,
        fact.claim_id,
        after={"status": item.verification_status.value, "reason": data.reason},
    )
    db.commit()
    return verified_view(item)
