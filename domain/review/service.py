from datetime import UTC, datetime
from typing import Any
from uuid import UUID

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from domain.assessment.models import AssessmentStatus, CoverageAssessment, EligibilityResult
from domain.calculation.service import calculate_assessment
from domain.claim.models import Claim, ClaimStatus
from domain.claim.service import ClaimStateMachine
from domain.evidence.service import build_for_calculation
from domain.fact.models import VerificationStatus, VerifiedFact
from domain.review.models import (
    AdditionalDocumentRequest,
    DocumentRequestStatus,
    Review,
    ReviewAssignment,
    ReviewStatus,
    ReviewType,
)
from domain.user.models import User, UserRole
from shared.errors import DomainError


class ReviewStateMachine:
    _allowed = {
        ReviewStatus.REQUESTED: frozenset({ReviewStatus.ASSIGNED}),
        ReviewStatus.ASSIGNED: frozenset({ReviewStatus.IN_PROGRESS}),
        ReviewStatus.IN_PROGRESS: frozenset(
            {
                ReviewStatus.APPROVED,
                ReviewStatus.MODIFIED,
                ReviewStatus.ADDITIONAL_DOCUMENT_REQUIRED,
                ReviewStatus.UNDETERMINED,
            }
        ),
        ReviewStatus.ADDITIONAL_DOCUMENT_REQUIRED: frozenset({ReviewStatus.IN_PROGRESS}),
        ReviewStatus.APPROVED: frozenset({ReviewStatus.COMPLETED}),
        ReviewStatus.MODIFIED: frozenset({ReviewStatus.COMPLETED}),
        ReviewStatus.UNDETERMINED: frozenset({ReviewStatus.COMPLETED}),
        ReviewStatus.COMPLETED: frozenset(),
    }

    @classmethod
    def transition(cls, review: Review, target: ReviewStatus) -> None:
        if target not in cls._allowed[review.review_status]:
            raise DomainError(
                "INVALID_REVIEW_STATE_TRANSITION",
                f"Review cannot transition from {review.review_status.value} to {target.value}",
                409,
            )
        review.review_status = target


def create_review(
    db: Session,
    claim: Claim,
    review_type: ReviewType,
    reason: str,
    assessment: CoverageAssessment | None = None,
) -> Review:
    if not reason.strip():
        raise DomainError("REVIEW_REASON_REQUIRED", "Review reason is required", 422)
    eligible = claim.status is ClaimStatus.MANUAL_REVIEW or (
        assessment is not None
        and assessment.eligibility_result
        in {
            EligibilityResult.MANUAL_REVIEW,
            EligibilityResult.POSSIBLE_EXCLUSION,
            EligibilityResult.UNDETERMINED,
        }
    )
    if not eligible:
        raise DomainError("REVIEW_NOT_ALLOWED", "Claim is not eligible for review", 409)
    existing = db.scalar(
        select(Review).where(
            Review.claim_id == claim.claim_id,
            Review.assessment_id == (assessment.assessment_id if assessment else None),
            Review.review_type == review_type,
            Review.review_status.not_in([ReviewStatus.COMPLETED]),
        )
    )
    if existing:
        return existing
    previous = {
        "eligibility_result": assessment.eligibility_result.value if assessment else None,
        "assessment_id": str(assessment.assessment_id) if assessment else None,
    }
    review = Review(
        claim_id=claim.claim_id,
        assessment_id=assessment.assessment_id if assessment else None,
        review_type=review_type,
        review_status=ReviewStatus.REQUESTED,
        reason=reason.strip(),
        previous_result=previous,
    )
    db.add(review)
    db.flush()
    return review


def assign_review(
    db: Session, review: Review, reviewer: User, assigned_by: UUID
) -> ReviewAssignment:
    if reviewer.role is not UserRole.ADJUSTER:
        raise DomainError("INVALID_REVIEWER", "Reviewer must have ADJUSTER role", 422)
    if review.review_status is not ReviewStatus.REQUESTED:
        raise DomainError("REVIEW_ALREADY_ASSIGNED", "Review is not available", 409)
    assignment = ReviewAssignment(
        review_id=review.review_id,
        reviewer_user_id=reviewer.user_id,
        assigned_by=assigned_by,
    )
    db.add(assignment)
    review.reviewer_user_id = reviewer.user_id
    ReviewStateMachine.transition(review, ReviewStatus.ASSIGNED)
    db.flush()
    return assignment


def assigned_review(db: Session, review_id: UUID, reviewer_id: UUID) -> Review:
    review = db.get(Review, review_id)
    if review is None:
        raise DomainError("REVIEW_NOT_FOUND", "Review was not found", 404)
    if review.reviewer_user_id != reviewer_id:
        raise DomainError("REVIEW_ACCESS_DENIED", "Review is assigned to another reviewer", 403)
    return review


def accept_review(db: Session, review: Review) -> None:
    ReviewStateMachine.transition(review, ReviewStatus.IN_PROGRESS)
    review.started_at = datetime.now(UTC)
    assignment = db.scalar(
        select(ReviewAssignment).where(ReviewAssignment.review_id == review.review_id)
    )
    if assignment:
        assignment.accepted_at = review.started_at


def approve_review(review: Review, opinion: str) -> None:
    ReviewStateMachine.transition(review, ReviewStatus.APPROVED)
    review.opinion = opinion.strip() or None
    review.final_result = dict(review.previous_result)


def modify_review(
    db: Session,
    review: Review,
    reviewer_id: UUID,
    fact_id: UUID,
    new_value: str,
    reason: str,
    final_eligibility: EligibilityResult,
    opinion: str | None,
) -> tuple[VerifiedFact, CoverageAssessment, Any | None]:
    if review.review_status is not ReviewStatus.IN_PROGRESS:
        raise DomainError("INVALID_REVIEW_STATE", "Review is not in progress", 409)
    if not reason.strip() or not new_value.strip():
        raise DomainError(
            "REVIEW_REASON_REQUIRED", "Value and modification reason are required", 422
        )
    original = db.get(VerifiedFact, fact_id)
    if original is None or original.claim_id != review.claim_id:
        raise DomainError("REVIEW_FACT_MISMATCH", "Fact does not belong to review claim", 409)
    original.verification_status = VerificationStatus.REJECTED
    replacement = VerifiedFact(
        claim_id=original.claim_id,
        extracted_fact_id=original.extracted_fact_id,
        fact_type=original.fact_type,
        verified_value=new_value.strip(),
        verification_status=VerificationStatus.EXPERT_MODIFIED,
        verified_by=reviewer_id,
        verified_at=datetime.now(UTC),
        modification_reason=reason.strip(),
        source_document_id=original.source_document_id,
        source_page=original.source_page,
        source_bbox=original.source_bbox,
    )
    db.add(replacement)
    source = db.get(CoverageAssessment, review.assessment_id) if review.assessment_id else None
    if source is None:
        raise DomainError("ASSESSMENT_NOT_FOUND", "Review assessment was not found", 404)
    assessment = CoverageAssessment(
        claim_id=source.claim_id,
        contract_coverage_id=source.contract_coverage_id,
        policy_version_id=source.policy_version_id,
        rule_version_id=source.rule_version_id,
        calculation_rule_version_id=source.calculation_rule_version_id,
        assessment_status=AssessmentStatus.COMPLETED,
        match_score=source.match_score,
        eligibility_result=final_eligibility,
        exclusion_result=source.exclusion_result,
        reduction_result=source.reduction_result,
        reason_summary="Expert structured override after evidence review",
        resolution_snapshot={
            **source.resolution_snapshot,
            "expert_review_id": str(review.review_id),
        },
    )
    db.add(assessment)
    db.flush()
    calculation = None
    evidence_version = None
    if final_eligibility in {EligibilityResult.PAYABLE, EligibilityResult.NOT_PAYABLE}:
        claim = db.get(Claim, review.claim_id)
        if claim is None:
            raise DomainError("CLAIM_NOT_FOUND", "Claim was not found", 404)
        calculation = calculate_assessment(db, assessment.assessment_id, claim.user_id)
        evidence = build_for_calculation(db, calculation.calculation_id, claim.user_id)
        evidence_version = evidence[0].evidence_version if evidence else None
    review.opinion = opinion.strip() if opinion else None
    review.final_result = {
        "previous_fact_id": str(original.verified_fact_id),
        "previous_value": original.verified_value,
        "new_fact_id": str(replacement.verified_fact_id),
        "new_value": replacement.verified_value,
        "eligibility_result": final_eligibility.value,
        "assessment_id": str(assessment.assessment_id),
        "calculation_id": str(calculation.calculation_id) if calculation else None,
        "evidence_version": evidence_version,
    }
    ReviewStateMachine.transition(review, ReviewStatus.MODIFIED)
    complete_review(db, review)
    return replacement, assessment, calculation


def request_documents(
    db: Session,
    review: Review,
    reviewer_id: UUID,
    document_type: str | None,
    fact_type: str | None,
    reason: str,
    user_message: str,
    internal_note: str | None,
) -> AdditionalDocumentRequest:
    if not reason.strip() or not user_message.strip():
        raise DomainError(
            "DOCUMENT_REQUEST_REASON_REQUIRED", "Reason and user message are required", 422
        )
    ReviewStateMachine.transition(review, ReviewStatus.ADDITIONAL_DOCUMENT_REQUIRED)
    submission_round = (
        int(
            db.scalar(
                select(
                    func.coalesce(func.max(AdditionalDocumentRequest.submission_round), 0)
                ).where(AdditionalDocumentRequest.review_id == review.review_id)
            )
            or 0
        )
        + 1
    )
    item = AdditionalDocumentRequest(
        submission_round=submission_round,
        review_id=review.review_id,
        claim_id=review.claim_id,
        requested_document_type=document_type,
        requested_fact_type=fact_type,
        reason=reason.strip(),
        user_message=user_message.strip(),
        internal_note=internal_note.strip() if internal_note else None,
        requested_by=reviewer_id,
    )
    db.add(item)
    claim = db.get(Claim, review.claim_id)
    if claim is None:
        raise DomainError("CLAIM_NOT_FOUND", "Claim was not found", 404)
    ClaimStateMachine.transition(claim, ClaimStatus.DOCUMENT_REQUIRED)
    return item


def resume_after_documents(
    db: Session, request_item: AdditionalDocumentRequest, user_id: UUID
) -> Review:
    from domain.document.models import DocumentProcessingStatus, MedicalDocument
    from domain.fact.models import ExtractedFact

    claim = db.get(Claim, request_item.claim_id)
    if claim is None or claim.user_id != user_id:
        raise DomainError("CLAIM_ACCESS_DENIED", "Claim belongs to another user", 403)
    if request_item.request_status is not DocumentRequestStatus.SUBMITTED:
        raise DomainError(
            "DOCUMENT_REQUEST_NOT_SUBMITTED", "Additional document is not submitted", 409
        )
    document = db.scalar(
        select(MedicalDocument).where(
            MedicalDocument.additional_document_request_id == request_item.request_id
        )
    )
    if document is None or document.processing_status is not DocumentProcessingStatus.COMPLETED:
        raise DomainError(
            "DOCUMENT_PROCESSING_INCOMPLETE", "Additional document is not processed", 409
        )
    extracted = list(
        db.scalars(select(ExtractedFact).where(ExtractedFact.document_id == document.document_id))
    )
    for fact in extracted:
        if (
            db.scalar(
                select(VerifiedFact).where(VerifiedFact.extracted_fact_id == fact.extracted_fact_id)
            )
            is None
        ):
            raise DomainError(
                "FACT_VERIFICATION_REQUIRED", "Additional facts require verification", 409
            )
    review = db.get(Review, request_item.review_id)
    if review is None:
        raise DomainError("REVIEW_NOT_FOUND", "Review was not found", 404)
    ReviewStateMachine.transition(review, ReviewStatus.IN_PROGRESS)
    request_item.request_status = DocumentRequestStatus.RESOLVED
    request_item.fulfilled_at = datetime.now(UTC)
    if claim.status is ClaimStatus.USER_VERIFICATION:
        ClaimStateMachine.transition(claim, ClaimStatus.MANUAL_REVIEW)
    return review


def mark_undetermined(review: Review, reason: str, opinion: str | None) -> None:
    if not reason.strip():
        raise DomainError("REVIEW_REASON_REQUIRED", "Reason is required", 422)
    ReviewStateMachine.transition(review, ReviewStatus.UNDETERMINED)
    review.reason = reason.strip()
    review.opinion = opinion.strip() if opinion else None
    review.final_result = {"eligibility_result": EligibilityResult.UNDETERMINED.value}


def complete_review(db: Session, review: Review) -> None:
    ReviewStateMachine.transition(review, ReviewStatus.COMPLETED)
    review.completed_at = datetime.now(UTC)
    claim = db.get(Claim, review.claim_id)
    if claim is None:
        raise DomainError("CLAIM_NOT_FOUND", "Claim was not found", 404)
    unresolved = db.scalar(
        select(Review).where(
            Review.claim_id == review.claim_id,
            Review.review_id != review.review_id,
            Review.review_status != ReviewStatus.COMPLETED,
        )
    )
    if unresolved is None and review.final_result:
        target = (
            ClaimStatus.MANUAL_REVIEW
            if review.final_result.get("eligibility_result") == EligibilityResult.UNDETERMINED.value
            else ClaimStatus.COMPLETED
        )
        if claim.status is ClaimStatus.MANUAL_REVIEW:
            ClaimStateMachine.transition(claim, target)


def review_view(review: Review) -> dict[str, Any]:
    return {
        "review_id": review.review_id,
        "claim_id": review.claim_id,
        "assessment_id": review.assessment_id,
        "reviewer_user_id": review.reviewer_user_id,
        "review_type": review.review_type,
        "review_status": review.review_status,
        "reason": review.reason,
        "opinion": review.opinion,
        "previous_result": review.previous_result,
        "final_result": review.final_result,
        "requested_at": review.requested_at,
        "started_at": review.started_at,
        "completed_at": review.completed_at,
    }
