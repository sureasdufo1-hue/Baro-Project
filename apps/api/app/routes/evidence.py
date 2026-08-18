from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, Request
from sqlalchemy import select
from sqlalchemy.orm import Session

from apps.api.app.audit import record_audit
from apps.api.app.dependencies import require_authenticated_user
from domain.assessment.models import CoverageAssessment
from domain.audit.models import AuditEventType, AuditResult
from domain.calculation.models import BenefitCalculation
from domain.calculation.service import calculation_view, owned_calculation
from domain.claim.service import owned_claim
from domain.contract.models import ContractCoverage
from domain.evidence.models import Evidence, EvidenceType
from domain.evidence.service import (
    build_for_calculation,
    complete_claim_if_ready,
    decision_trace,
    evidence_view,
    validate_evidence_chain,
)
from domain.user.models import User
from infrastructure.database.session import get_db
from shared.errors import DomainError

calculation_router = APIRouter(prefix="/api/calculations", tags=["evidence"])
claim_router = APIRouter(prefix="/api/claims", tags=["results"])


def _audit(
    db: Session,
    request: Request,
    user: User,
    calculation: BenefitCalculation,
    event: AuditEventType,
) -> None:
    record_audit(
        db,
        event_type=event,
        result=AuditResult.SUCCESS,
        actor_user_id=user.user_id,
        object_type="BenefitCalculation",
        object_id=str(calculation.calculation_id),
        claim_id=calculation.claim_id,
        request_id=request.state.request_id,
        source_ip=request.client.host if request.client else None,
        after_value={"calculation_version": calculation.calculation_version},
    )


@calculation_router.post("/{calculation_id}/evidence", status_code=201, response_model=None)
def build_evidence(
    calculation_id: UUID,
    request: Request,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> list[dict[str, Any]]:
    calculation = owned_calculation(db, calculation_id, user.user_id)
    records = build_for_calculation(db, calculation_id, user.user_id)
    complete_claim_if_ready(db, calculation.claim_id)
    _audit(db, request, user, calculation, AuditEventType.EVIDENCE_BUILD)
    db.commit()
    return [evidence_view(item) for item in records]


def _evidence_response(
    calculation_id: UUID,
    request: Request,
    user: User,
    db: Session,
    event: AuditEventType,
    evidence_type: EvidenceType | None = None,
) -> list[dict[str, Any]]:
    calculation = owned_calculation(db, calculation_id, user.user_id)
    query = select(Evidence).where(Evidence.calculation_id == calculation_id)
    if evidence_type is not None:
        query = query.where(Evidence.evidence_type == evidence_type)
    records = list(db.scalars(query.order_by(Evidence.created_at)))
    _audit(db, request, user, calculation, event)
    db.commit()
    return [evidence_view(item) for item in records]


@calculation_router.get("/{calculation_id}/evidence", response_model=None)
def get_evidence(
    calculation_id: UUID,
    request: Request,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> list[dict[str, Any]]:
    return _evidence_response(calculation_id, request, user, db, AuditEventType.EVIDENCE_VIEW)


@calculation_router.get("/{calculation_id}/policy-evidence", response_model=None)
def get_policy_evidence(
    calculation_id: UUID,
    request: Request,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> list[dict[str, Any]]:
    return _evidence_response(
        calculation_id,
        request,
        user,
        db,
        AuditEventType.POLICY_EVIDENCE_VIEW,
        EvidenceType.POLICY_CLAUSE,
    )


@calculation_router.get("/{calculation_id}/fact-evidence", response_model=None)
def get_fact_evidence(
    calculation_id: UUID,
    request: Request,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> list[dict[str, Any]]:
    return _evidence_response(
        calculation_id,
        request,
        user,
        db,
        AuditEventType.EVIDENCE_VIEW,
        EvidenceType.VERIFIED_FACT,
    )


@calculation_router.get("/{calculation_id}/trace", response_model=None)
def get_trace(
    calculation_id: UUID,
    request: Request,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> list[dict[str, Any]]:
    calculation = owned_calculation(db, calculation_id, user.user_id)
    result = decision_trace(db, calculation)
    _audit(db, request, user, calculation, AuditEventType.DECISION_TRACE_VIEW)
    db.commit()
    return result


@claim_router.get("/{claim_id}/result", response_model=None)
def claim_result(
    claim_id: UUID,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> dict[str, Any]:
    claim = owned_claim(db, claim_id, user.user_id)
    calculations = list(
        db.scalars(
            select(BenefitCalculation).where(
                BenefitCalculation.claim_id == claim_id,
                BenefitCalculation.is_current.is_(True),
            )
        )
    )
    items = []
    complete_total = 0
    for calculation in calculations:
        assessment = db.get(CoverageAssessment, calculation.assessment_id)
        coverage = db.get(ContractCoverage, calculation.contract_coverage_id)
        evidence = list(
            db.scalars(
                select(Evidence).where(Evidence.calculation_id == calculation.calculation_id)
            )
        )
        evidence_complete = True
        try:
            validate_evidence_chain(calculation, evidence)
        except DomainError:
            evidence_complete = False
        if evidence_complete and calculation.calculation_status.value in {
            "CALCULATED",
            "NOT_PAYABLE",
        }:
            complete_total += calculation.final_amount
        items.append(
            {
                **calculation_view(calculation),
                "coverage_name": coverage.coverage_name_snapshot if coverage else None,
                "eligibility_result": assessment.eligibility_result if assessment else None,
                "reason_summary": assessment.reason_summary if assessment else None,
                "policy_version_id": assessment.policy_version_id if assessment else None,
                "evidence_complete": evidence_complete,
                "result_status": "READY" if evidence_complete else "RESULT_INCOMPLETE",
            }
        )
    return {
        "claim_id": claim.claim_id,
        "claim_number": claim.claim_number,
        "claim_status": claim.status,
        "analysis_date": claim.updated_at,
        "total_expected_amount": complete_total,
        "total_label": "현재 근거가 완성된 자동계산 담보 기준 예상합계",
        "items": items,
    }
