from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, Request
from sqlalchemy import select
from sqlalchemy.orm import Session

from apps.api.app.audit import record_audit
from apps.api.app.dependencies import require_authenticated_user
from domain.audit.models import AuditEventType, AuditResult
from domain.calculation.models import BenefitCalculation
from domain.calculation.service import calculate_assessment, calculation_view, owned_calculation
from domain.claim.service import owned_claim
from domain.user.models import User
from infrastructure.database.session import get_db

claim_router = APIRouter(prefix="/api/claims", tags=["calculations"])
assessment_router = APIRouter(prefix="/api/assessments", tags=["calculations"])
router = APIRouter(prefix="/api/calculations", tags=["calculations"])


def audit(
    db: Session, request: Request, user: User, item: BenefitCalculation, event: AuditEventType
) -> None:
    record_audit(
        db,
        event_type=event,
        result=AuditResult.SUCCESS,
        actor_user_id=user.user_id,
        object_type="BenefitCalculation",
        object_id=str(item.calculation_id),
        claim_id=item.claim_id,
        request_id=request.state.request_id,
        source_ip=request.client.host if request.client else None,
        after_value={
            "version": item.calculation_version,
            "rule_version_id": str(item.rule_version_id),
            "status": item.calculation_status.value,
            "final_amount": item.final_amount,
        },
    )


@assessment_router.post("/{assessment_id}/calculate", status_code=201, response_model=None)
def calculate_one(
    assessment_id: UUID,
    request: Request,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> dict[str, Any]:
    item = calculate_assessment(db, assessment_id, user.user_id)
    audit(db, request, user, item, AuditEventType.CALCULATION_COMPLETE)
    db.commit()
    return calculation_view(item)


@assessment_router.post("/{assessment_id}/recalculate", status_code=201, response_model=None)
def recalculate(
    assessment_id: UUID,
    request: Request,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> dict[str, Any]:
    item = calculate_assessment(db, assessment_id, user.user_id)
    audit(db, request, user, item, AuditEventType.CALCULATION_RECALCULATE)
    db.commit()
    return calculation_view(item)


@claim_router.get("/{claim_id}/calculations", response_model=None)
def list_claim_calculations(
    claim_id: UUID, user: User = Depends(require_authenticated_user), db: Session = Depends(get_db)
) -> list[dict[str, Any]]:
    owned_claim(db, claim_id, user.user_id)
    return [
        calculation_view(x)
        for x in db.scalars(
            select(BenefitCalculation)
            .where(BenefitCalculation.claim_id == claim_id)
            .order_by(BenefitCalculation.created_at.desc())
        )
    ]


@router.get("/{calculation_id}", response_model=None)
def detail(
    calculation_id: UUID,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> dict[str, Any]:
    return calculation_view(owned_calculation(db, calculation_id, user.user_id))


@router.get("/{calculation_id}/history", response_model=None)
def calculation_history(
    calculation_id: UUID,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> list[dict[str, Any]]:
    item = owned_calculation(db, calculation_id, user.user_id)
    return [
        calculation_view(x)
        for x in db.scalars(
            select(BenefitCalculation)
            .where(BenefitCalculation.assessment_id == item.assessment_id)
            .order_by(BenefitCalculation.calculation_version.desc())
        )
    ]


@assessment_router.get("/{assessment_id}/calculations", response_model=None)
def history(
    assessment_id: UUID,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> list[dict[str, Any]]:
    from domain.assessment.service import owned_assessment

    owned_assessment(db, assessment_id, user.user_id)
    return [
        calculation_view(x)
        for x in db.scalars(
            select(BenefitCalculation)
            .where(BenefitCalculation.assessment_id == assessment_id)
            .order_by(BenefitCalculation.calculation_version.desc())
        )
    ]
