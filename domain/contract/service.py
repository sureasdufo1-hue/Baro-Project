from datetime import date
from typing import Any
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from domain.contract.models import (
    ContractCoverage,
    InsuranceContract,
    Insured,
    RelationshipType,
)
from domain.policy.models import Coverage, MasterStatus, Policy, PolicyVersion, ProductVersion
from shared.errors import DomainError


def validate_period(start: date | None, end: date | None, code: str) -> None:
    if start and end and start >= end:
        raise DomainError(code, "Start date must be before end date", 422)


def owned_insured(db: Session, insured_id: UUID, user_id: UUID) -> Insured:
    insured = db.get(Insured, insured_id)
    if insured is None:
        raise DomainError("INSURED_NOT_FOUND", "Insured was not found", 404)
    if insured.owner_user_id != user_id:
        raise DomainError("INSURED_ACCESS_DENIED", "Insured belongs to another user", 403)
    return insured


def owned_contract(db: Session, contract_id: UUID, user_id: UUID) -> InsuranceContract:
    contract = db.scalar(
        select(InsuranceContract)
        .options(selectinload(InsuranceContract.coverages))
        .where(InsuranceContract.contract_id == contract_id)
    )
    if contract is None:
        raise DomainError("INSURANCE_CONTRACT_NOT_FOUND", "Contract was not found", 404)
    if contract.user_id != user_id:
        raise DomainError("CONTRACT_ACCESS_DENIED", "Contract belongs to another user", 403)
    return contract


def create_insured(db: Session, user_id: UUID, data: dict[str, Any]) -> Insured:
    if data.get("relationship_type") is RelationshipType.SELF:
        existing = db.scalar(
            select(Insured).where(
                Insured.owner_user_id == user_id, Insured.relationship_type == RelationshipType.SELF
            )
        )
        if existing:
            raise DomainError("SELF_INSURED_CONFLICT", "A SELF insured already exists", 409)
    insured = Insured(owner_user_id=user_id, **data)
    db.add(insured)
    db.flush()
    return insured


def validate_master_links(
    db: Session, product_version_id: UUID, policy_version_id: UUID | None
) -> None:
    if db.get(ProductVersion, product_version_id) is None:
        raise DomainError("PRODUCT_VERSION_NOT_FOUND", "Product version was not found", 404)
    if policy_version_id:
        version = db.get(PolicyVersion, policy_version_id)
        if version is None:
            raise DomainError("POLICY_VERSION_NOT_FOUND", "Policy version was not found", 404)
        policy = db.get(Policy, version.policy_id)
        if policy is None or policy.product_version_id != product_version_id:
            raise DomainError(
                "POLICY_VERSION_NOT_APPLICABLE",
                "Policy version does not belong to the selected product version",
                422,
            )


def build_coverage(
    db: Session, data: dict[str, Any], contract_start: date | None, contract_end: date | None
) -> ContractCoverage:
    coverage = db.get(Coverage, data["coverage_id"])
    if coverage is None:
        raise DomainError("COVERAGE_NOT_FOUND", "Coverage was not found", 404)
    if coverage.status is not MasterStatus.ACTIVE:
        raise DomainError("COVERAGE_NOT_ACTIVE", "Coverage is not active", 422)
    amount = data["insured_amount"]
    if isinstance(amount, bool) or not isinstance(amount, int) or amount < 0:
        raise DomainError(
            "INVALID_INSURED_AMOUNT", "Insured amount must be a nonnegative integer KRW value", 422
        )
    start, end = data.get("coverage_start_date"), data.get("coverage_end_date")
    validate_period(start, end, "INVALID_COVERAGE_PERIOD")
    if contract_start and start and start < contract_start:
        raise DomainError(
            "INVALID_COVERAGE_PERIOD", "Coverage starts before the contract coverage period", 422
        )
    if contract_end and end and end > contract_end:
        raise DomainError(
            "INVALID_COVERAGE_PERIOD", "Coverage ends after the contract coverage period", 422
        )
    return ContractCoverage(**data)


def create_contract(
    db: Session, user_id: UUID, data: dict[str, Any], coverage_inputs: list[dict[str, Any]]
) -> InsuranceContract:
    owned_insured(db, data["insured_id"], user_id)
    validate_master_links(db, data["product_version_id"], data.get("policy_version_id"))
    validate_period(
        data.get("coverage_start_date"), data.get("coverage_end_date"), "INVALID_CONTRACT_PERIOD"
    )
    if (
        data.get("contract_date")
        and data.get("coverage_start_date")
        and data["contract_date"] > data["coverage_start_date"]
    ):
        raise DomainError(
            "INVALID_CONTRACT_PERIOD", "Contract date must not be after coverage start", 422
        )
    contract = InsuranceContract(user_id=user_id, **data)
    db.add(contract)
    db.flush()
    for item in coverage_inputs:
        coverage = build_coverage(
            db, item, contract.coverage_start_date, contract.coverage_end_date
        )
        coverage.contract_id = contract.contract_id
        db.add(coverage)
    db.flush()
    return contract


def list_owned_contracts(
    db: Session, user_id: UUID, limit: int, offset: int
) -> list[InsuranceContract]:
    return list(
        db.scalars(
            select(InsuranceContract)
            .options(selectinload(InsuranceContract.coverages))
            .where(InsuranceContract.user_id == user_id)
            .order_by(InsuranceContract.created_at.desc())
            .limit(limit)
            .offset(offset)
        )
    )


def add_coverage(
    db: Session, contract: InsuranceContract, data: dict[str, Any]
) -> ContractCoverage:
    item = build_coverage(db, data, contract.coverage_start_date, contract.coverage_end_date)
    item.contract_id = contract.contract_id
    db.add(item)
    db.flush()
    return item


def owned_contract_coverage(
    db: Session, contract: InsuranceContract, item_id: UUID
) -> ContractCoverage:
    item = db.get(ContractCoverage, item_id)
    if item is None:
        raise DomainError("CONTRACT_COVERAGE_NOT_FOUND", "Contract coverage was not found", 404)
    if item.contract_id != contract.contract_id:
        raise DomainError(
            "CONTRACT_ACCESS_DENIED", "Coverage does not belong to this contract", 403
        )
    return item
