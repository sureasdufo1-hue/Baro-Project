from datetime import UTC, date, datetime
from typing import Any
from uuid import UUID, uuid4

from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from domain.claim.models import Accident, Claim, ClaimStatus, ClaimType
from domain.contract.models import InsuranceContract
from domain.contract.service import owned_contract
from shared.errors import DomainError


class ClaimStateMachine:
    """The single authority for claim process state changes."""

    _allowed: dict[ClaimStatus, frozenset[ClaimStatus]] = {
        ClaimStatus.DRAFT: frozenset({ClaimStatus.DOCUMENT_REQUIRED, ClaimStatus.CANCELLED}),
        ClaimStatus.DOCUMENT_REQUIRED: frozenset(
            {ClaimStatus.DOCUMENT_PROCESSING, ClaimStatus.CANCELLED}
        ),
        ClaimStatus.DOCUMENT_PROCESSING: frozenset(
            {ClaimStatus.USER_VERIFICATION, ClaimStatus.FAILED, ClaimStatus.CANCELLED}
        ),
        ClaimStatus.USER_VERIFICATION: frozenset(
            {ClaimStatus.ASSESSING, ClaimStatus.MANUAL_REVIEW, ClaimStatus.CANCELLED}
        ),
        ClaimStatus.ASSESSING: frozenset(
            {
                ClaimStatus.DOCUMENT_REQUIRED,
                ClaimStatus.MANUAL_REVIEW,
                ClaimStatus.COMPLETED,
                ClaimStatus.FAILED,
                ClaimStatus.CANCELLED,
            }
        ),
        ClaimStatus.MANUAL_REVIEW: frozenset(
            {
                ClaimStatus.DOCUMENT_REQUIRED,
                ClaimStatus.ASSESSING,
                ClaimStatus.COMPLETED,
                ClaimStatus.CANCELLED,
            }
        ),
        ClaimStatus.COMPLETED: frozenset(),
        ClaimStatus.FAILED: frozenset(),
        ClaimStatus.CANCELLED: frozenset(),
        ClaimStatus.CLOSED: frozenset(),
    }

    @classmethod
    def transition(cls, claim: Claim, target: ClaimStatus) -> tuple[ClaimStatus, ClaimStatus]:
        source = claim.status
        if target not in cls._allowed[source]:
            raise DomainError(
                "INVALID_CLAIM_STATE_TRANSITION",
                f"Claim cannot transition from {source.value} to {target.value}",
                409,
            )
        claim.status = target
        if target is ClaimStatus.COMPLETED:
            claim.completed_at = datetime.now(UTC)
        return source, target


def validate_accident(claim_type: ClaimType, data: dict[str, Any]) -> None:
    if claim_type is ClaimType.DISEASE and not (
        data.get("diagnosis_date") or data.get("onset_date")
    ):
        raise DomainError(
            "INVALID_ACCIDENT_INFORMATION", "Disease claims need diagnosis or onset date", 422
        )
    if claim_type is ClaimType.INJURY and not data.get("accident_date"):
        raise DomainError(
            "INVALID_ACCIDENT_INFORMATION", "Injury claims need an accident date", 422
        )
    if claim_type is ClaimType.OTHER and not (data.get("description") or "").strip():
        raise DomainError("INVALID_ACCIDENT_INFORMATION", "Other claims need a description", 422)


def accident_is_complete(accident: Accident) -> bool:
    values = {
        "accident_date": accident.accident_date,
        "diagnosis_date": accident.diagnosis_date,
        "onset_date": accident.onset_date,
        "description": accident.description,
    }
    try:
        validate_accident(accident.accident_type, values)
    except DomainError:
        return False
    return True


def claim_number() -> str:
    # The date is useful to operators; UUID entropy plus a DB unique constraint prevents collisions.
    return f"CLM-{date.today():%Y%m%d}-{uuid4().hex[:12].upper()}"


def create_claim(
    db: Session,
    user_id: UUID,
    contract_id: UUID,
    claim_type: ClaimType,
    title: str | None,
    accident_data: dict[str, Any],
) -> Claim:
    contract: InsuranceContract = owned_contract(db, contract_id, user_id)
    validate_accident(claim_type, accident_data)
    claim = Claim(
        user_id=user_id,
        insured_id=contract.insured_id,
        contract_id=contract.contract_id,
        claim_number=claim_number(),
        claim_type=claim_type,
        status=ClaimStatus.DRAFT,
        title=(title or f"{claim_type.value.title()} claim").strip(),
    )
    claim.accident = Accident(accident_type=claim_type, **accident_data)
    db.add(claim)
    db.flush()
    return claim


def owned_claim(db: Session, claim_id: UUID, user_id: UUID) -> Claim:
    claim = db.scalar(
        select(Claim).options(selectinload(Claim.accident)).where(Claim.claim_id == claim_id)
    )
    if claim is None:
        raise DomainError("CLAIM_NOT_FOUND", "Claim was not found", 404)
    if claim.user_id != user_id:
        raise DomainError("CLAIM_ACCESS_DENIED", "Claim belongs to another user", 403)
    return claim


def list_claims(
    db: Session,
    user_id: UUID,
    limit: int,
    offset: int,
    status: ClaimStatus | None = None,
    claim_type: ClaimType | None = None,
) -> list[Claim]:
    stmt = select(Claim).where(Claim.user_id == user_id)
    if status:
        stmt = stmt.where(Claim.status == status)
    if claim_type:
        stmt = stmt.where(Claim.claim_type == claim_type)
    return list(db.scalars(stmt.order_by(Claim.created_at.desc()).limit(limit).offset(offset)))


def update_claim(claim: Claim, changes: dict[str, Any]) -> None:
    if claim.status is not ClaimStatus.DRAFT:
        raise DomainError("INVALID_CLAIM_STATE", "Only draft claims can be modified", 409)
    new_type = changes.get("claim_type", claim.claim_type)
    if new_type is not claim.claim_type:
        validate_accident(
            new_type,
            {
                "accident_date": claim.accident.accident_date,
                "diagnosis_date": claim.accident.diagnosis_date,
                "onset_date": claim.accident.onset_date,
                "description": claim.accident.description,
            },
        )
        claim.accident.accident_type = new_type
    for key, value in changes.items():
        setattr(claim, key, value)


def update_accident(claim: Claim, changes: dict[str, Any]) -> None:
    if claim.status is not ClaimStatus.DRAFT:
        raise DomainError("INVALID_CLAIM_STATE", "Accident can only be modified in draft", 409)
    candidate = {
        "accident_date": changes.get("accident_date", claim.accident.accident_date),
        "diagnosis_date": changes.get("diagnosis_date", claim.accident.diagnosis_date),
        "onset_date": changes.get("onset_date", claim.accident.onset_date),
        "description": changes.get("description", claim.accident.description),
    }
    validate_accident(claim.claim_type, candidate)
    for key, value in changes.items():
        setattr(claim.accident, key, value)


def submit_accident_information(claim: Claim) -> tuple[ClaimStatus, ClaimStatus]:
    if not accident_is_complete(claim.accident):
        raise DomainError("INVALID_ACCIDENT_INFORMATION", "Accident information is incomplete", 422)
    return ClaimStateMachine.transition(claim, ClaimStatus.DOCUMENT_REQUIRED)


def cancel_claim(claim: Claim) -> tuple[ClaimStatus, ClaimStatus]:
    return ClaimStateMachine.transition(claim, ClaimStatus.CANCELLED)
