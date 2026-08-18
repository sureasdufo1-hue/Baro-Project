from datetime import date
from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, Query, Request
from pydantic import BaseModel, Field, StrictInt, model_validator
from sqlalchemy import select
from sqlalchemy.orm import Session

from apps.api.app.audit import record_audit
from apps.api.app.dependencies import require_authenticated_user
from domain.audit.models import AuditEventType, AuditResult
from domain.contract.models import (
    ContractStatus,
    CoverageStatus,
    Gender,
    InsuranceContract,
    Insured,
    RegistrationMethod,
    RelationshipType,
)
from domain.contract.service import (
    add_coverage,
    create_contract,
    create_insured,
    list_owned_contracts,
    owned_contract,
    owned_contract_coverage,
    owned_insured,
)
from domain.policy.models import (
    Coverage,
    InsuranceCompany,
    InsuranceProduct,
    MasterStatus,
    ProductVersion,
)
from domain.user.models import User
from infrastructure.database.session import get_db
from shared.errors import DomainError

router = APIRouter(prefix="/api", tags=["contracts"])


@router.get("/catalog/insurance-companies", response_model=None)
def catalog_companies(
    _: User = Depends(require_authenticated_user), db: Session = Depends(get_db)
) -> list[Any]:
    return list(
        db.scalars(
            select(InsuranceCompany)
            .where(InsuranceCompany.status == MasterStatus.ACTIVE)
            .order_by(InsuranceCompany.company_name)
        )
    )


@router.get("/catalog/insurance-products", response_model=None)
def catalog_products(
    company_id: UUID, _: User = Depends(require_authenticated_user), db: Session = Depends(get_db)
) -> list[Any]:
    return list(
        db.scalars(
            select(InsuranceProduct)
            .where(
                InsuranceProduct.company_id == company_id,
                InsuranceProduct.status == MasterStatus.ACTIVE,
            )
            .order_by(InsuranceProduct.product_name)
        )
    )


@router.get("/catalog/product-versions", response_model=None)
def catalog_versions(
    product_id: UUID,
    contract_date: date | None = None,
    _: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> list[Any]:
    stmt = select(ProductVersion).where(ProductVersion.product_id == product_id)
    if contract_date:
        stmt = stmt.where(
            (ProductVersion.sale_start_date.is_(None))
            | (ProductVersion.sale_start_date <= contract_date),
            (ProductVersion.sale_end_date.is_(None))
            | (ProductVersion.sale_end_date >= contract_date),
        )
    return list(db.scalars(stmt.order_by(ProductVersion.effective_from.desc())))


@router.get("/catalog/coverages", response_model=None)
def catalog_coverages(
    _: User = Depends(require_authenticated_user), db: Session = Depends(get_db)
) -> list[Any]:
    return list(
        db.scalars(
            select(Coverage)
            .where(Coverage.status == MasterStatus.ACTIVE)
            .order_by(Coverage.coverage_name)
        )
    )


class InsuredCreate(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    birth_date: date | None = None
    gender: Gender = Gender.UNKNOWN
    relationship_type: RelationshipType
    identity_token: None = None


class InsuredPatch(BaseModel):
    name: str | None = None
    birth_date: date | None = None
    gender: Gender | None = None
    relationship_type: RelationshipType | None = None


class CoverageInput(BaseModel):
    coverage_id: UUID
    coverage_name_snapshot: str = Field(min_length=1, max_length=250)
    insured_amount: StrictInt = Field(ge=0)
    coverage_start_date: date | None = None
    coverage_end_date: date | None = None
    payment_limit: StrictInt | None = Field(default=None, ge=0)
    payment_count_limit: StrictInt | None = Field(default=None, ge=0)

    @model_validator(mode="after")
    def period(self) -> "CoverageInput":
        if (
            self.coverage_start_date
            and self.coverage_end_date
            and self.coverage_start_date >= self.coverage_end_date
        ):
            raise ValueError("Invalid coverage period")
        return self


class ContractCreate(BaseModel):
    insured_id: UUID
    product_version_id: UUID
    policy_version_id: UUID | None = None
    policy_number: str | None = Field(default=None, max_length=150)
    contract_date: date | None = None
    coverage_start_date: date | None = None
    coverage_end_date: date | None = None
    coverages: list[CoverageInput] = Field(default_factory=list)


class ContractPatch(BaseModel):
    policy_number: str | None = None
    contract_date: date | None = None
    coverage_start_date: date | None = None
    coverage_end_date: date | None = None
    contract_status: ContractStatus | None = None


class CoveragePatch(BaseModel):
    insured_amount: StrictInt | None = Field(default=None, ge=0)
    coverage_name_snapshot: str | None = None
    coverage_start_date: date | None = None
    coverage_end_date: date | None = None
    status: CoverageStatus | None = None

    @model_validator(mode="after")
    def period(self) -> "CoveragePatch":
        if (
            self.coverage_start_date
            and self.coverage_end_date
            and self.coverage_start_date >= self.coverage_end_date
        ):
            raise ValueError("Invalid coverage period")
        return self


def audit(
    db: Session,
    request: Request,
    user: User,
    event: AuditEventType,
    obj_type: str,
    obj_id: UUID,
    before: dict[str, Any] | None = None,
    after: dict[str, Any] | None = None,
) -> None:
    record_audit(
        db,
        event_type=event,
        result=AuditResult.SUCCESS,
        actor_user_id=user.user_id,
        object_type=obj_type,
        object_id=str(obj_id),
        request_id=request.state.request_id,
        source_ip=request.client.host if request.client else None,
        before_value=before,
        after_value=after,
    )


@router.get("/insureds", response_model=None)
def list_insureds(
    user: User = Depends(require_authenticated_user), db: Session = Depends(get_db)
) -> list[Insured]:
    return list(
        db.scalars(
            select(Insured)
            .where(Insured.owner_user_id == user.user_id)
            .order_by(Insured.created_at)
        )
    )


@router.post("/insureds", status_code=201, response_model=None)
def post_insured(
    data: InsuredCreate,
    request: Request,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> Insured:
    obj = create_insured(db, user.user_id, data.model_dump(exclude={"identity_token"}))
    audit(
        db,
        request,
        user,
        AuditEventType.INSURED_CREATE,
        "Insured",
        obj.insured_id,
        after={"relationship_type": obj.relationship_type.value},
    )
    db.commit()
    db.refresh(obj)
    return obj


@router.get("/insureds/{insured_id}", response_model=None)
def get_insured(
    insured_id: UUID,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> Insured:
    return owned_insured(db, insured_id, user.user_id)


@router.patch("/insureds/{insured_id}", response_model=None)
def patch_insured(
    insured_id: UUID,
    data: InsuredPatch,
    request: Request,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> Insured:
    obj = owned_insured(db, insured_id, user.user_id)
    before = {
        "name": obj.name,
        "birth_date": obj.birth_date.isoformat() if obj.birth_date else None,
        "relationship_type": obj.relationship_type.value,
    }
    for key, value in data.model_dump(exclude_unset=True).items():
        setattr(obj, key, value)
    audit(
        db,
        request,
        user,
        AuditEventType.INSURED_MODIFY,
        "Insured",
        obj.insured_id,
        before,
        data.model_dump(mode="json", exclude_unset=True),
    )
    db.commit()
    db.refresh(obj)
    return obj


@router.get("/contracts", response_model=None)
def list_contracts(
    limit: int = Query(50, le=200),
    offset: int = 0,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> list[Any]:
    return list_owned_contracts(db, user.user_id, limit, offset)


@router.post("/contracts", status_code=201, response_model=None)
def post_contract(
    data: ContractCreate,
    request: Request,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> InsuranceContract:
    raw = data.model_dump(exclude={"coverages"})
    raw["registration_method"] = RegistrationMethod.MANUAL
    obj = create_contract(db, user.user_id, raw, [x.model_dump() for x in data.coverages])
    audit(
        db,
        request,
        user,
        AuditEventType.CONTRACT_CREATE,
        "InsuranceContract",
        obj.contract_id,
        after={
            "product_version_id": str(obj.product_version_id),
            "contract_date": obj.contract_date.isoformat() if obj.contract_date else None,
            "coverage_count": len(data.coverages),
        },
    )
    db.commit()
    db.refresh(obj)
    return obj


@router.get("/contracts/{contract_id}", response_model=None)
def get_contract(
    contract_id: UUID,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> InsuranceContract:
    return owned_contract(db, contract_id, user.user_id)


@router.patch("/contracts/{contract_id}", response_model=None)
def patch_contract(
    contract_id: UUID,
    data: ContractPatch,
    request: Request,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> InsuranceContract:
    obj = owned_contract(db, contract_id, user.user_id)
    before = {
        "policy_number": obj.policy_number,
        "contract_date": obj.contract_date.isoformat() if obj.contract_date else None,
        "coverage_start_date": obj.coverage_start_date.isoformat()
        if obj.coverage_start_date
        else None,
        "coverage_end_date": obj.coverage_end_date.isoformat() if obj.coverage_end_date else None,
        "contract_status": obj.contract_status.value,
    }
    changes = data.model_dump(exclude_unset=True)
    start = changes.get("coverage_start_date", obj.coverage_start_date)
    end = changes.get("coverage_end_date", obj.coverage_end_date)
    contract_date = changes.get("contract_date", obj.contract_date)
    if start and end and start >= end:
        raise DomainError("INVALID_CONTRACT_PERIOD", "Invalid contract period", 422)
    if contract_date and start and contract_date > start:
        raise DomainError("INVALID_CONTRACT_PERIOD", "Contract date is after coverage start", 422)
    for key, value in changes.items():
        setattr(obj, key, value)
    audit(
        db,
        request,
        user,
        AuditEventType.CONTRACT_MODIFY,
        "InsuranceContract",
        obj.contract_id,
        before,
        data.model_dump(mode="json", exclude_unset=True),
    )
    db.commit()
    db.refresh(obj)
    return obj


@router.post("/contracts/{contract_id}/coverages", status_code=201, response_model=None)
def post_coverage(
    contract_id: UUID,
    data: CoverageInput,
    request: Request,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> Any:
    contract = owned_contract(db, contract_id, user.user_id)
    obj = add_coverage(db, contract, data.model_dump())
    audit(
        db,
        request,
        user,
        AuditEventType.CONTRACT_COVERAGE_CREATE,
        "ContractCoverage",
        obj.contract_coverage_id,
        after={"coverage_id": str(obj.coverage_id), "insured_amount": obj.insured_amount},
    )
    db.commit()
    db.refresh(obj)
    return obj


@router.patch("/contracts/{contract_id}/coverages/{item_id}", response_model=None)
def patch_coverage(
    contract_id: UUID,
    item_id: UUID,
    data: CoveragePatch,
    request: Request,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> Any:
    contract = owned_contract(db, contract_id, user.user_id)
    obj = owned_contract_coverage(db, contract, item_id)
    before = {
        "insured_amount": obj.insured_amount,
        "status": obj.status.value,
        "coverage_name_snapshot": obj.coverage_name_snapshot,
    }
    changes = data.model_dump(exclude_unset=True)
    start = changes.get("coverage_start_date", obj.coverage_start_date)
    end = changes.get("coverage_end_date", obj.coverage_end_date)
    if start and end and start >= end:
        raise DomainError("INVALID_COVERAGE_PERIOD", "Invalid coverage period", 422)
    if contract.coverage_start_date and start and start < contract.coverage_start_date:
        raise DomainError("INVALID_COVERAGE_PERIOD", "Coverage starts before contract", 422)
    if contract.coverage_end_date and end and end > contract.coverage_end_date:
        raise DomainError("INVALID_COVERAGE_PERIOD", "Coverage ends after contract", 422)
    for key, value in changes.items():
        setattr(obj, key, value)
    event = (
        AuditEventType.CONTRACT_COVERAGE_DEACTIVATE
        if changes.get("status") is CoverageStatus.CANCELLED
        else AuditEventType.CONTRACT_COVERAGE_MODIFY
    )
    audit(
        db,
        request,
        user,
        event,
        "ContractCoverage",
        obj.contract_coverage_id,
        before,
        data.model_dump(mode="json", exclude_unset=True),
    )
    db.commit()
    db.refresh(obj)
    return obj
