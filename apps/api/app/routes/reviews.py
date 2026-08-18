from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session

from apps.api.app.audit import record_audit
from apps.api.app.dependencies import require_authenticated_user, require_role
from domain.assessment.models import CoverageAssessment, EligibilityResult
from domain.audit.models import AuditEventType, AuditResult
from domain.calculation.models import BenefitCalculation
from domain.claim.models import Claim
from domain.claim.service import owned_claim
from domain.document.models import MedicalDocument
from domain.evidence.models import Evidence
from domain.evidence.service import evidence_view
from domain.fact.models import VerifiedFact
from domain.review.models import AdditionalDocumentRequest, Review, ReviewStatus, ReviewType
from domain.review.service import (
    accept_review,
    approve_review,
    assign_review,
    assigned_review,
    complete_review,
    create_review,
    mark_undetermined,
    modify_review,
    request_documents,
    resume_after_documents,
    review_view,
)
from domain.user.models import User, UserRole
from infrastructure.database.session import get_db
from shared.errors import DomainError

router = APIRouter(prefix="/api/reviews", tags=["reviews"])
claim_router = APIRouter(prefix="/api/claims", tags=["reviews"])


class ReviewCreate(BaseModel):
    claim_id: UUID
    assessment_id: UUID | None = None
    review_type: ReviewType
    reason: str = Field(min_length=1, max_length=2000)


class AssignRequest(BaseModel):
    reviewer_user_id: UUID


class OpinionRequest(BaseModel):
    opinion: str = Field(default="", max_length=4000)


class ModifyRequest(BaseModel):
    fact_id: UUID
    new_value: str = Field(min_length=1, max_length=1000)
    reason: str = Field(min_length=1, max_length=2000)
    final_eligibility: EligibilityResult
    opinion: str | None = Field(default=None, max_length=4000)


class DocumentRequest(BaseModel):
    requested_document_type: str | None = Field(default=None, max_length=100)
    requested_fact_type: str | None = Field(default=None, max_length=100)
    reason: str = Field(min_length=1, max_length=2000)
    user_message: str = Field(min_length=1, max_length=2000)
    internal_note: str | None = Field(default=None, max_length=4000)


class UndeterminedRequest(BaseModel):
    reason: str = Field(min_length=1, max_length=2000)
    opinion: str | None = Field(default=None, max_length=4000)


def audit_review(
    db: Session,
    request: Request,
    user: User,
    review: Review,
    event: AuditEventType,
    before: dict[str, Any] | None = None,
) -> None:
    record_audit(
        db,
        event_type=event,
        result=AuditResult.SUCCESS,
        actor_user_id=user.user_id,
        object_type="Review",
        object_id=str(review.review_id),
        claim_id=review.claim_id,
        request_id=request.state.request_id,
        source_ip=request.client.host if request.client else None,
        before_value=before,
        after_value={
            "status": review.review_status.value,
            "final_result": review.final_result,
        },
    )


@router.post("", status_code=201, response_model=None)
def create(
    data: ReviewCreate,
    request: Request,
    user: User = Depends(require_role(UserRole.SYSTEM_ADMIN)),
    db: Session = Depends(get_db),
) -> dict[str, Any]:
    claim = db.get(Claim, data.claim_id)
    if claim is None:
        raise DomainError("CLAIM_NOT_FOUND", "Claim was not found", 404)
    assessment = db.get(CoverageAssessment, data.assessment_id) if data.assessment_id else None
    if assessment and assessment.claim_id != claim.claim_id:
        raise DomainError("REVIEW_ASSESSMENT_MISMATCH", "Assessment belongs to another claim", 409)
    review = create_review(db, claim, data.review_type, data.reason, assessment)
    audit_review(db, request, user, review, AuditEventType.REVIEW_CREATE)
    db.commit()
    return review_view(review)


@router.get("", response_model=None)
def queue(
    status: ReviewStatus | None = None,
    review_type: ReviewType | None = None,
    _: User = Depends(require_role(UserRole.SYSTEM_ADMIN)),
    db: Session = Depends(get_db),
) -> list[dict[str, Any]]:
    query = select(Review)
    if status:
        query = query.where(Review.review_status == status)
    if review_type:
        query = query.where(Review.review_type == review_type)
    return [review_view(item) for item in db.scalars(query.order_by(Review.requested_at))]


@router.get("/my", response_model=None)
def my_queue(
    status: ReviewStatus | None = None,
    user: User = Depends(require_role(UserRole.ADJUSTER)),
    db: Session = Depends(get_db),
) -> list[dict[str, Any]]:
    query = select(Review).where(Review.reviewer_user_id == user.user_id)
    if status:
        query = query.where(Review.review_status == status)
    return [review_view(item) for item in db.scalars(query.order_by(Review.requested_at))]


@router.get("/{review_id}", response_model=None)
def detail(
    review_id: UUID,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> dict[str, Any]:
    if user.role is UserRole.SYSTEM_ADMIN:
        review = db.get(Review, review_id)
        if review is None:
            raise DomainError("REVIEW_NOT_FOUND", "Review was not found", 404)
    elif user.role is UserRole.ADJUSTER:
        review = assigned_review(db, review_id, user.user_id)
    else:
        raise DomainError("ACCESS_DENIED", "Expert permission is required", 403)
    return review_view(review)


@router.get("/{review_id}/context", response_model=None)
def context(
    review_id: UUID,
    user: User = Depends(require_role(UserRole.ADJUSTER)),
    db: Session = Depends(get_db),
) -> dict[str, Any]:
    review = assigned_review(db, review_id, user.user_id)
    calculations = list(
        db.scalars(select(BenefitCalculation).where(BenefitCalculation.claim_id == review.claim_id))
    )
    evidence = list(db.scalars(select(Evidence).where(Evidence.claim_id == review.claim_id)))
    facts = list(db.scalars(select(VerifiedFact).where(VerifiedFact.claim_id == review.claim_id)))
    documents = list(
        db.scalars(select(MedicalDocument).where(MedicalDocument.claim_id == review.claim_id))
    )
    return {
        "review": review_view(review),
        "calculations": [
            {
                "calculation_id": item.calculation_id,
                "version": item.calculation_version,
                "status": item.calculation_status,
                "final_amount": item.final_amount,
                "formula": item.calculation_formula,
            }
            for item in calculations
        ],
        "evidence": [evidence_view(item) for item in evidence],
        "facts": [
            {
                "verified_fact_id": item.verified_fact_id,
                "fact_type": item.fact_type,
                "verified_value": item.verified_value,
                "verification_status": item.verification_status,
                "source_document_id": item.source_document_id,
                "source_page": item.source_page,
                "source_bbox": item.source_bbox,
            }
            for item in facts
        ],
        "documents": [
            {
                "document_id": item.document_id,
                "document_type": item.document_type,
                "filename": item.original_filename,
                "content_url": f"/api/documents/{item.document_id}/content",
            }
            for item in documents
        ],
    }


@router.post("/{review_id}/assign", response_model=None)
def assign(
    review_id: UUID,
    data: AssignRequest,
    request: Request,
    user: User = Depends(require_role(UserRole.SYSTEM_ADMIN)),
    db: Session = Depends(get_db),
) -> dict[str, Any]:
    review = db.get(Review, review_id)
    reviewer = db.get(User, data.reviewer_user_id)
    if review is None or reviewer is None:
        raise DomainError("REVIEW_OR_REVIEWER_NOT_FOUND", "Review or reviewer was not found", 404)
    assign_review(db, review, reviewer, user.user_id)
    audit_review(db, request, user, review, AuditEventType.REVIEW_ASSIGN)
    db.commit()
    return review_view(review)


def expert_action(db: Session, review_id: UUID, user: User) -> Review:
    return assigned_review(db, review_id, user.user_id)


@router.post("/{review_id}/accept", response_model=None)
def accept(
    review_id: UUID,
    request: Request,
    user: User = Depends(require_role(UserRole.ADJUSTER)),
    db: Session = Depends(get_db),
) -> dict[str, Any]:
    review = expert_action(db, review_id, user)
    accept_review(db, review)
    audit_review(db, request, user, review, AuditEventType.REVIEW_ACCEPT)
    db.commit()
    return review_view(review)


@router.post("/{review_id}/approve", response_model=None)
def approve(
    review_id: UUID,
    data: OpinionRequest,
    request: Request,
    user: User = Depends(require_role(UserRole.ADJUSTER)),
    db: Session = Depends(get_db),
) -> dict[str, Any]:
    review = expert_action(db, review_id, user)
    before = dict(review.previous_result)
    approve_review(review, data.opinion)
    audit_review(db, request, user, review, AuditEventType.REVIEW_APPROVE, before)
    db.commit()
    return review_view(review)


@router.post("/{review_id}/modify", response_model=None)
def modify(
    review_id: UUID,
    data: ModifyRequest,
    request: Request,
    user: User = Depends(require_role(UserRole.ADJUSTER)),
    db: Session = Depends(get_db),
) -> dict[str, Any]:
    review = expert_action(db, review_id, user)
    before = dict(review.previous_result)
    modify_review(
        db,
        review,
        user.user_id,
        data.fact_id,
        data.new_value,
        data.reason,
        data.final_eligibility,
        data.opinion,
    )
    audit_review(db, request, user, review, AuditEventType.REVIEW_MODIFY, before)
    db.commit()
    return review_view(review)


@router.post("/{review_id}/request-documents", response_model=None)
def documents(
    review_id: UUID,
    data: DocumentRequest,
    request: Request,
    user: User = Depends(require_role(UserRole.ADJUSTER)),
    db: Session = Depends(get_db),
) -> dict[str, Any]:
    review = expert_action(db, review_id, user)
    item = request_documents(
        db,
        review,
        user.user_id,
        data.requested_document_type,
        data.requested_fact_type,
        data.reason,
        data.user_message,
        data.internal_note,
    )
    audit_review(db, request, user, review, AuditEventType.REVIEW_DOCUMENT_REQUEST)
    db.commit()
    return {"request_id": item.request_id, "review_status": review.review_status}


@router.post("/{review_id}/undetermined", response_model=None)
def undetermined(
    review_id: UUID,
    data: UndeterminedRequest,
    request: Request,
    user: User = Depends(require_role(UserRole.ADJUSTER)),
    db: Session = Depends(get_db),
) -> dict[str, Any]:
    review = expert_action(db, review_id, user)
    mark_undetermined(review, data.reason, data.opinion)
    audit_review(db, request, user, review, AuditEventType.REVIEW_UNDETERMINED)
    db.commit()
    return review_view(review)


@router.post("/{review_id}/complete", response_model=None)
def complete(
    review_id: UUID,
    request: Request,
    user: User = Depends(require_role(UserRole.ADJUSTER)),
    db: Session = Depends(get_db),
) -> dict[str, Any]:
    review = expert_action(db, review_id, user)
    complete_review(db, review)
    audit_review(db, request, user, review, AuditEventType.REVIEW_COMPLETE)
    db.commit()
    return review_view(review)


@claim_router.get("/{claim_id}/review-status", response_model=None)
def user_review_status(
    claim_id: UUID, user: User = Depends(require_authenticated_user), db: Session = Depends(get_db)
) -> dict[str, Any]:
    claim = owned_claim(db, claim_id, user.user_id)
    reviews = list(
        db.scalars(select(Review).where(Review.claim_id == claim_id).order_by(Review.requested_at))
    )
    requests = list(
        db.scalars(
            select(AdditionalDocumentRequest).where(AdditionalDocumentRequest.claim_id == claim_id)
        )
    )
    return {
        "claim_id": claim.claim_id,
        "claim_status": claim.status,
        "reviews": [
            {
                "review_status": x.review_status,
                "review_type": x.review_type,
                "requested_at": x.requested_at,
            }
            for x in reviews
        ],
        "document_requests": [
            {
                "request_id": x.request_id,
                "submission_round": x.submission_round,
                "requested_document_type": x.requested_document_type,
                "requested_fact_type": x.requested_fact_type,
                "user_message": x.user_message,
                "request_status": x.request_status,
            }
            for x in requests
        ],
    }


@claim_router.post(
    "/{claim_id}/additional-document-requests/{request_id}/resume", response_model=None
)
def resume_review_after_documents(
    claim_id: UUID,
    request_id: UUID,
    request: Request,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> dict[str, Any]:
    owned_claim(db, claim_id, user.user_id)
    item = db.get(AdditionalDocumentRequest, request_id)
    if item is None or item.claim_id != claim_id:
        raise DomainError("DOCUMENT_REQUEST_NOT_FOUND", "Document request was not found", 404)
    review = resume_after_documents(db, item, user.user_id)
    audit_review(db, request, user, review, AuditEventType.REVIEW_RESUMED)
    db.commit()
    return {
        "review_id": review.review_id,
        "review_status": review.review_status,
        "request_status": item.request_status,
        "submission_round": item.submission_round,
    }
