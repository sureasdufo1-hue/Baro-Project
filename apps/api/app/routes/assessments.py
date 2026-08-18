from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, Request
from sqlalchemy import select
from sqlalchemy.orm import Session

from apps.api.app.audit import record_audit
from apps.api.app.dependencies import require_authenticated_user
from domain.assessment.models import CoverageAssessment
from domain.assessment.service import assessment_view, create_assessments, owned_assessment
from domain.audit.models import AuditEventType, AuditResult
from domain.claim.service import owned_claim
from domain.user.models import User
from infrastructure.database.session import get_db

claim_router = APIRouter(prefix="/api/claims", tags=["assessments"])
router = APIRouter(prefix="/api/assessments", tags=["assessments"])


@claim_router.post("/{claim_id}/assess", status_code=201, response_model=None)
def assess(
    claim_id: UUID,
    request: Request,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> list[dict[str, Any]]:
    items = create_assessments(db, claim_id, user.user_id)
    for item in items:
        for event in (AuditEventType.ASSESSMENT_CREATED, AuditEventType.ASSESSMENT_COMPLETED):
            record_audit(
                db,
                event_type=event,
                result=AuditResult.SUCCESS,
                actor_user_id=user.user_id,
                object_type="CoverageAssessment",
                object_id=str(item.assessment_id),
                claim_id=claim_id,
                request_id=request.state.request_id,
                source_ip=request.client.host if request.client else None,
                after_value={"result": item.eligibility_result.value},
            )
    db.commit()
    return [assessment_view(item) for item in items]


@claim_router.get("/{claim_id}/assessments", response_model=None)
def list_assessments(
    claim_id: UUID, user: User = Depends(require_authenticated_user), db: Session = Depends(get_db)
) -> list[dict[str, Any]]:
    owned_claim(db, claim_id, user.user_id)
    items = list(
        db.scalars(
            select(CoverageAssessment)
            .where(CoverageAssessment.claim_id == claim_id)
            .order_by(CoverageAssessment.created_at.desc())
        )
    )
    return [assessment_view(item) for item in items]


@router.get("/{assessment_id}", response_model=None)
def detail(
    assessment_id: UUID,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> dict[str, Any]:
    return assessment_view(owned_assessment(db, assessment_id, user.user_id))
