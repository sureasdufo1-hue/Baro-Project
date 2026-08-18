from datetime import date
from typing import Any, Literal
from uuid import UUID

from fastapi import APIRouter, Depends, Query, Request
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from apps.api.app.audit import record_audit
from apps.api.app.dependencies import require_authenticated_user
from domain.audit.models import AuditEventType, AuditResult
from domain.claim.models import Accident, Claim, ClaimStatus, ClaimType
from domain.claim.service import (
    cancel_claim,
    create_claim,
    list_claims,
    owned_claim,
    submit_accident_information,
    update_accident,
    update_claim,
)
from domain.user.models import User
from infrastructure.database.session import get_db

router = APIRouter(prefix="/api/claims", tags=["claims"])


def claim_view(claim: Claim) -> dict[str, Any]:
    accident = claim.accident
    return {
        "claim_id": claim.claim_id,
        "user_id": claim.user_id,
        "insured_id": claim.insured_id,
        "contract_id": claim.contract_id,
        "claim_number": claim.claim_number,
        "claim_type": claim.claim_type,
        "status": claim.status,
        "title": claim.title,
        "created_at": claim.created_at,
        "updated_at": claim.updated_at,
        "completed_at": claim.completed_at,
        "accident": accident,
    }


class AccidentInput(BaseModel):
    accident_date: date | None = None
    diagnosis_date: date | None = None
    onset_date: date | None = None
    description: str | None = Field(default=None, max_length=4000)
    location: str | None = Field(default=None, max_length=300)


class ClaimCreate(BaseModel):
    contract_id: UUID
    claim_type: ClaimType
    title: str | None = Field(default=None, max_length=200)
    accident: AccidentInput


class ClaimPatch(BaseModel):
    title: str | None = Field(default=None, min_length=1, max_length=200)
    claim_type: ClaimType | None = None


class AccidentPatch(BaseModel):
    accident_date: date | None = None
    diagnosis_date: date | None = None
    onset_date: date | None = None
    description: str | None = Field(default=None, max_length=4000)
    location: str | None = Field(default=None, max_length=300)


class TransitionInput(BaseModel):
    action: Literal["SUBMIT_ACCIDENT_INFORMATION"]


def audit(
    db: Session,
    request: Request,
    user: User,
    event: AuditEventType,
    claim: Claim,
    before: dict[str, Any] | None = None,
    after: dict[str, Any] | None = None,
) -> None:
    record_audit(
        db,
        event_type=event,
        result=AuditResult.SUCCESS,
        actor_user_id=user.user_id,
        object_type="Claim",
        object_id=str(claim.claim_id),
        claim_id=claim.claim_id,
        request_id=request.state.request_id,
        source_ip=request.client.host if request.client else None,
        before_value=before,
        after_value=after,
    )


@router.get("", response_model=None)
def get_claims(
    status: ClaimStatus | None = None,
    claim_type: ClaimType | None = None,
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> list[dict[str, Any]]:
    return [
        claim_view(item)
        for item in list_claims(db, user.user_id, limit, offset, status, claim_type)
    ]


@router.post("", status_code=201, response_model=None)
def post_claim(
    data: ClaimCreate,
    request: Request,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> dict[str, Any]:
    claim = create_claim(
        db, user.user_id, data.contract_id, data.claim_type, data.title, data.accident.model_dump()
    )
    audit(
        db,
        request,
        user,
        AuditEventType.CLAIM_CREATE,
        claim,
        after={
            "contract_id": str(claim.contract_id),
            "insured_id": str(claim.insured_id),
            "claim_type": claim.claim_type.value,
            "status": claim.status.value,
        },
    )
    record_audit(
        db,
        event_type=AuditEventType.ACCIDENT_CREATE,
        result=AuditResult.SUCCESS,
        actor_user_id=user.user_id,
        object_type="Accident",
        object_id=str(claim.accident.accident_id),
        claim_id=claim.claim_id,
        request_id=request.state.request_id,
        source_ip=request.client.host if request.client else None,
        after_value={"accident_type": claim.accident.accident_type.value},
    )
    db.commit()
    db.refresh(claim)
    return claim_view(claim)


@router.get("/{claim_id}", response_model=None)
def get_claim(
    claim_id: UUID, user: User = Depends(require_authenticated_user), db: Session = Depends(get_db)
) -> dict[str, Any]:
    return claim_view(owned_claim(db, claim_id, user.user_id))


@router.patch("/{claim_id}", response_model=None)
def patch_claim(
    claim_id: UUID,
    data: ClaimPatch,
    request: Request,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> dict[str, Any]:
    claim = owned_claim(db, claim_id, user.user_id)
    before = {"claim_type": claim.claim_type.value, "title": claim.title}
    update_claim(claim, data.model_dump(exclude_unset=True))
    audit(
        db,
        request,
        user,
        AuditEventType.CLAIM_MODIFY,
        claim,
        before,
        data.model_dump(mode="json", exclude_unset=True),
    )
    db.commit()
    db.refresh(claim)
    return claim_view(claim)


@router.get("/{claim_id}/accident", response_model=None)
def get_accident(
    claim_id: UUID, user: User = Depends(require_authenticated_user), db: Session = Depends(get_db)
) -> Accident:
    return owned_claim(db, claim_id, user.user_id).accident


@router.patch("/{claim_id}/accident", response_model=None)
def patch_accident(
    claim_id: UUID,
    data: AccidentPatch,
    request: Request,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> Accident:
    claim = owned_claim(db, claim_id, user.user_id)
    before = {
        "accident_date": (
            claim.accident.accident_date.isoformat() if claim.accident.accident_date else None
        ),
        "diagnosis_date": (
            claim.accident.diagnosis_date.isoformat() if claim.accident.diagnosis_date else None
        ),
        "onset_date": claim.accident.onset_date.isoformat() if claim.accident.onset_date else None,
        "description_changed": False,
    }
    changes = data.model_dump(exclude_unset=True)
    update_accident(claim, changes)
    after = data.model_dump(mode="json", exclude_unset=True, exclude={"description"})
    if "description" in changes:
        after["description_changed"] = True
    audit(db, request, user, AuditEventType.ACCIDENT_MODIFY, claim, before, after)
    db.commit()
    db.refresh(claim.accident)
    return claim.accident


@router.post("/{claim_id}/transitions", response_model=None)
def transition_claim(
    claim_id: UUID,
    _: TransitionInput,
    request: Request,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> dict[str, Any]:
    claim = owned_claim(db, claim_id, user.user_id)
    source, target = submit_accident_information(claim)
    audit(
        db,
        request,
        user,
        AuditEventType.CLAIM_STATUS_CHANGE,
        claim,
        {"status": source.value},
        {"status": target.value},
    )
    db.commit()
    db.refresh(claim)
    return claim_view(claim)


@router.post("/{claim_id}/cancel", response_model=None)
def post_cancel(
    claim_id: UUID,
    request: Request,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> dict[str, Any]:
    claim = owned_claim(db, claim_id, user.user_id)
    source, target = cancel_claim(claim)
    audit(
        db,
        request,
        user,
        AuditEventType.CLAIM_CANCEL,
        claim,
        {"status": source.value},
        {"status": target.value},
    )
    audit(
        db,
        request,
        user,
        AuditEventType.CLAIM_STATUS_CHANGE,
        claim,
        {"status": source.value},
        {"status": target.value},
    )
    db.commit()
    db.refresh(claim)
    return claim_view(claim)
