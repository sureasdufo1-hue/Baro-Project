from datetime import date
from typing import Any, cast
from uuid import UUID

from fastapi import APIRouter, Depends, Query, Request
from pydantic import BaseModel, Field, model_validator
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from apps.api.app.audit import record_audit
from apps.api.app.dependencies import require_role
from domain.audit.models import AuditEventType, AuditResult
from domain.policy.models import (
    Coverage,
    CoverageAlias,
    InsuranceCompany,
    InsuranceProduct,
    InsuranceType,
    MasterStatus,
    Policy,
    PolicyClause,
    PolicyType,
    PolicyVersion,
    PolicyVersionStatus,
    ProductVersion,
    VersionStatus,
)
from domain.rule.models import (
    BenefitRule,
    BenefitRuleClause,
    LogicalOperator,
    RuleCondition,
    RuleOperator,
    RuleSourceType,
    RuleStatus,
    RuleType,
    RuleVersion,
)
from domain.user.models import User, UserRole
from infrastructure.database.session import get_db
from shared.errors import DomainError

router = APIRouter(prefix="/api/admin", tags=["insurance-master"])
policy_roles = require_role(UserRole.POLICY_EDITOR, UserRole.SYSTEM_ADMIN)
coverage_roles = require_role(UserRole.POLICY_EDITOR, UserRole.RULE_EDITOR, UserRole.SYSTEM_ADMIN)
rule_roles = require_role(UserRole.RULE_EDITOR, UserRole.SYSTEM_ADMIN)


class PeriodModel(BaseModel):
    @model_validator(mode="after")
    def validate_periods(self) -> "PeriodModel":
        for start_name, end_name in (
            ("sale_start_date", "sale_end_date"),
            ("effective_from", "effective_to"),
        ):
            start, end = getattr(self, start_name, None), getattr(self, end_name, None)
            if start and end and start > end:
                raise ValueError(f"{start_name} must not be after {end_name}")
        return self


class CompanyCreate(BaseModel):
    company_code: str = Field(min_length=1, max_length=50)
    company_name: str = Field(min_length=1, max_length=200)
    company_type: str = Field(min_length=1, max_length=50)


class CompanyPatch(BaseModel):
    company_name: str | None = None
    company_type: str | None = None
    status: MasterStatus | None = None


class ProductCreate(BaseModel):
    company_id: UUID
    product_code: str
    product_name: str
    insurance_type: InsuranceType


class ProductVersionCreate(PeriodModel):
    product_id: UUID
    version_name: str
    sale_start_date: date | None = None
    sale_end_date: date | None = None
    effective_from: date | None = None
    effective_to: date | None = None
    status: VersionStatus = VersionStatus.DRAFT


class PolicyCreate(BaseModel):
    product_version_id: UUID
    policy_name: str
    policy_type: PolicyType


class PolicyVersionCreate(PeriodModel):
    policy_id: UUID
    version_code: str
    effective_from: date
    effective_to: date | None = None
    published_date: date | None = None
    previous_version_id: UUID | None = None
    file_hash: str | None = None
    source_file_uri: str | None = None
    original_filename: str | None = None


class ClauseCreate(BaseModel):
    policy_version_id: UUID
    article_number: str | None = None
    article_title: str | None = None
    paragraph_number: str | None = None
    item_number: str | None = None
    clause_text: str = Field(min_length=1)
    page_number: int | None = None
    source_bbox: dict[str, Any] | None = None
    text_hash: str | None = None


class CoverageCreate(BaseModel):
    standard_code: str
    coverage_name: str
    coverage_category: str
    insurance_type: InsuranceType
    description: str | None = None


class AliasCreate(BaseModel):
    coverage_id: UUID
    company_id: UUID | None = None
    alias_name: str
    normalized_name: str


class RuleCreate(BaseModel):
    coverage_id: UUID
    policy_version_id: UUID
    rule_name: str
    rule_type: RuleType


class RuleVersionCreate(PeriodModel):
    rule_id: UUID
    version_no: int = Field(gt=0)
    rule_definition: dict[str, Any] = Field(default_factory=lambda: {"conditions": []})
    effective_from: date | None = None
    effective_to: date | None = None
    source_type: RuleSourceType = RuleSourceType.MANUAL
    status: RuleStatus = RuleStatus.DRAFT


class ConditionCreate(BaseModel):
    rule_version_id: UUID
    sequence_no: int = Field(ge=1)
    fact_path: str
    operator: RuleOperator
    comparison_value: Any | None = None
    logical_operator: LogicalOperator = LogicalOperator.AND


class RuleClauseCreate(BaseModel):
    rule_id: UUID
    clause_id: UUID
    relation_type: str = "SOURCE"


def get_or_error(db: Session, model: type[Any], object_id: UUID, code: str) -> Any:
    value = db.get(model, object_id)
    if value is None:
        raise DomainError(code, "Requested insurance master record was not found", 404)
    return value


def commit(db: Session, conflict_code: str) -> None:
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise DomainError(conflict_code, "A conflicting record already exists", 409) from None


def flush(db: Session, conflict_code: str) -> None:
    try:
        db.flush()
    except IntegrityError:
        db.rollback()
        raise DomainError(conflict_code, "A conflicting record already exists", 409) from None


def audit_create(
    db: Session, request: Request, user: User, event: AuditEventType, obj: Any, id_name: str
) -> None:
    record_audit(
        db,
        event_type=event,
        result=AuditResult.SUCCESS,
        actor_user_id=user.user_id,
        object_type=type(obj).__name__,
        object_id=str(getattr(obj, id_name)),
        request_id=request.state.request_id,
        source_ip=request.client.host if request.client else None,
        after_value={id_name: str(getattr(obj, id_name))},
    )


def page(stmt: Any, db: Session, limit: int, offset: int) -> list[Any]:
    return list(db.scalars(stmt.limit(limit).offset(offset)))


@router.get("/insurance-companies", response_model=None)
def list_companies(
    search: str | None = None,
    status: MasterStatus | None = None,
    limit: int = Query(50, le=200),
    offset: int = 0,
    _: User = Depends(policy_roles),
    db: Session = Depends(get_db),
) -> list[InsuranceCompany]:
    stmt = select(InsuranceCompany).order_by(InsuranceCompany.company_name)
    if search:
        stmt = stmt.where(InsuranceCompany.company_name.ilike(f"%{search}%"))
    if status:
        stmt = stmt.where(InsuranceCompany.status == status)
    return page(stmt, db, limit, offset)


@router.post("/insurance-companies", status_code=201, response_model=None)
def create_company(
    data: CompanyCreate,
    request: Request,
    user: User = Depends(policy_roles),
    db: Session = Depends(get_db),
) -> InsuranceCompany:
    obj = InsuranceCompany(**data.model_dump())
    db.add(obj)
    flush(db, "INSURANCE_COMPANY_CODE_CONFLICT")
    audit_create(db, request, user, AuditEventType.INSURANCE_COMPANY_CREATE, obj, "company_id")
    commit(db, "INSURANCE_COMPANY_CODE_CONFLICT")
    db.refresh(obj)
    return obj


@router.patch("/insurance-companies/{company_id}", response_model=None)
def patch_company(
    company_id: UUID,
    data: CompanyPatch,
    request: Request,
    user: User = Depends(policy_roles),
    db: Session = Depends(get_db),
) -> InsuranceCompany:
    obj = cast(
        InsuranceCompany,
        get_or_error(db, InsuranceCompany, company_id, "INSURANCE_COMPANY_NOT_FOUND"),
    )
    before = {
        "company_name": obj.company_name,
        "company_type": obj.company_type,
        "status": obj.status.value,
    }
    for key, value in data.model_dump(exclude_unset=True).items():
        setattr(obj, key, value)
    record_audit(
        db,
        event_type=AuditEventType.INSURANCE_COMPANY_MODIFY,
        result=AuditResult.SUCCESS,
        actor_user_id=user.user_id,
        object_type="InsuranceCompany",
        object_id=str(obj.company_id),
        request_id=request.state.request_id,
        source_ip=request.client.host if request.client else None,
        before_value=before,
        after_value=data.model_dump(mode="json", exclude_unset=True),
    )
    commit(db, "INSURANCE_COMPANY_CODE_CONFLICT")
    db.refresh(obj)
    return obj


@router.get("/insurance-products", response_model=None)
def list_products(
    company_id: UUID | None = None,
    search: str | None = None,
    limit: int = Query(50, le=200),
    offset: int = 0,
    _: User = Depends(policy_roles),
    db: Session = Depends(get_db),
) -> list[InsuranceProduct]:
    stmt = select(InsuranceProduct).order_by(InsuranceProduct.product_name)
    if company_id:
        stmt = stmt.where(InsuranceProduct.company_id == company_id)
    if search:
        stmt = stmt.where(InsuranceProduct.product_name.ilike(f"%{search}%"))
    return page(stmt, db, limit, offset)


@router.post("/insurance-products", status_code=201, response_model=None)
def create_product(
    data: ProductCreate,
    request: Request,
    user: User = Depends(policy_roles),
    db: Session = Depends(get_db),
) -> InsuranceProduct:
    get_or_error(db, InsuranceCompany, data.company_id, "INSURANCE_COMPANY_NOT_FOUND")
    obj = InsuranceProduct(**data.model_dump())
    db.add(obj)
    flush(db, "INSURANCE_PRODUCT_CODE_CONFLICT")
    audit_create(db, request, user, AuditEventType.INSURANCE_PRODUCT_CREATE, obj, "product_id")
    commit(db, "INSURANCE_PRODUCT_CODE_CONFLICT")
    db.refresh(obj)
    return obj


@router.post("/product-versions", status_code=201, response_model=None)
def create_product_version(
    data: ProductVersionCreate,
    request: Request,
    user: User = Depends(policy_roles),
    db: Session = Depends(get_db),
) -> ProductVersion:
    get_or_error(db, InsuranceProduct, data.product_id, "INSURANCE_PRODUCT_NOT_FOUND")
    obj = ProductVersion(**data.model_dump())
    db.add(obj)
    flush(db, "PRODUCT_VERSION_CONFLICT")
    audit_create(
        db, request, user, AuditEventType.PRODUCT_VERSION_CREATE, obj, "product_version_id"
    )
    commit(db, "PRODUCT_VERSION_CONFLICT")
    db.refresh(obj)
    return obj


@router.get("/policies", response_model=None)
def list_policies(
    product_version_id: UUID | None = None,
    limit: int = Query(50, le=200),
    offset: int = 0,
    _: User = Depends(policy_roles),
    db: Session = Depends(get_db),
) -> list[Policy]:
    stmt = select(Policy).order_by(Policy.policy_name)
    if product_version_id:
        stmt = stmt.where(Policy.product_version_id == product_version_id)
    return page(stmt, db, limit, offset)


@router.post("/policies", status_code=201, response_model=None)
def create_policy(
    data: PolicyCreate,
    request: Request,
    user: User = Depends(policy_roles),
    db: Session = Depends(get_db),
) -> Policy:
    get_or_error(db, ProductVersion, data.product_version_id, "PRODUCT_VERSION_NOT_FOUND")
    obj = Policy(**data.model_dump())
    db.add(obj)
    flush(db, "POLICY_CONFLICT")
    audit_create(db, request, user, AuditEventType.POLICY_CREATE, obj, "policy_id")
    commit(db, "POLICY_CONFLICT")
    db.refresh(obj)
    return obj


@router.post("/policy-versions", status_code=201, response_model=None)
def create_policy_version(
    data: PolicyVersionCreate,
    request: Request,
    user: User = Depends(policy_roles),
    db: Session = Depends(get_db),
) -> PolicyVersion:
    get_or_error(db, Policy, data.policy_id, "POLICY_NOT_FOUND")
    if data.previous_version_id:
        previous = get_or_error(
            db, PolicyVersion, data.previous_version_id, "POLICY_VERSION_NOT_FOUND"
        )
        if previous.policy_id != data.policy_id:
            raise DomainError(
                "POLICY_VERSION_INVALID_PREVIOUS",
                "Previous version must belong to the same policy",
                422,
            )
    obj = PolicyVersion(**data.model_dump(), status=PolicyVersionStatus.DRAFT)
    db.add(obj)
    flush(db, "POLICY_VERSION_CONFLICT")
    audit_create(db, request, user, AuditEventType.POLICY_VERSION_CREATE, obj, "policy_version_id")
    commit(db, "POLICY_VERSION_CONFLICT")
    db.refresh(obj)
    return obj


@router.post("/policy-clauses", status_code=201, response_model=None)
def create_clause(
    data: ClauseCreate,
    request: Request,
    user: User = Depends(policy_roles),
    db: Session = Depends(get_db),
) -> PolicyClause:
    version = get_or_error(db, PolicyVersion, data.policy_version_id, "POLICY_VERSION_NOT_FOUND")
    if version.status in {PolicyVersionStatus.ACTIVE, PolicyVersionStatus.DEPRECATED}:
        raise DomainError(
            "POLICY_VERSION_IMMUTABLE", "Active or deprecated policy versions cannot be edited", 409
        )
    obj = PolicyClause(**data.model_dump())
    db.add(obj)
    flush(db, "POLICY_CLAUSE_CONFLICT")
    audit_create(db, request, user, AuditEventType.POLICY_CLAUSE_CREATE, obj, "clause_id")
    commit(db, "POLICY_CLAUSE_CONFLICT")
    db.refresh(obj)
    return obj


@router.get("/coverages", response_model=None)
def list_coverages(
    search: str | None = None,
    limit: int = Query(50, le=200),
    offset: int = 0,
    _: User = Depends(coverage_roles),
    db: Session = Depends(get_db),
) -> list[Coverage]:
    stmt = select(Coverage).order_by(Coverage.coverage_name)
    if search:
        stmt = stmt.where(Coverage.coverage_name.ilike(f"%{search}%"))
    return page(stmt, db, limit, offset)


@router.post("/coverages", status_code=201, response_model=None)
def create_coverage(
    data: CoverageCreate,
    request: Request,
    user: User = Depends(coverage_roles),
    db: Session = Depends(get_db),
) -> Coverage:
    obj = Coverage(**data.model_dump())
    db.add(obj)
    flush(db, "COVERAGE_CODE_CONFLICT")
    audit_create(db, request, user, AuditEventType.COVERAGE_CREATE, obj, "coverage_id")
    commit(db, "COVERAGE_CODE_CONFLICT")
    db.refresh(obj)
    return obj


@router.post("/coverage-aliases", status_code=201, response_model=None)
def create_alias(
    data: AliasCreate, user: User = Depends(coverage_roles), db: Session = Depends(get_db)
) -> CoverageAlias:
    get_or_error(db, Coverage, data.coverage_id, "COVERAGE_NOT_FOUND")
    if data.company_id:
        get_or_error(db, InsuranceCompany, data.company_id, "INSURANCE_COMPANY_NOT_FOUND")
    obj = CoverageAlias(**data.model_dump())
    db.add(obj)
    commit(db, "COVERAGE_ALIAS_CONFLICT")
    db.refresh(obj)
    return obj


@router.get("/rules", response_model=None)
def list_rules(
    limit: int = Query(50, le=200),
    offset: int = 0,
    _: User = Depends(rule_roles),
    db: Session = Depends(get_db),
) -> list[BenefitRule]:
    return page(select(BenefitRule).order_by(BenefitRule.rule_name), db, limit, offset)


@router.post("/rules", status_code=201, response_model=None)
def create_rule(
    data: RuleCreate,
    request: Request,
    user: User = Depends(rule_roles),
    db: Session = Depends(get_db),
) -> BenefitRule:
    get_or_error(db, Coverage, data.coverage_id, "COVERAGE_NOT_FOUND")
    get_or_error(db, PolicyVersion, data.policy_version_id, "POLICY_VERSION_NOT_FOUND")
    obj = BenefitRule(**data.model_dump(), status=RuleStatus.DRAFT)
    db.add(obj)
    flush(db, "RULE_CONFLICT")
    audit_create(db, request, user, AuditEventType.RULE_CREATE, obj, "rule_id")
    commit(db, "RULE_CONFLICT")
    db.refresh(obj)
    return obj


@router.post("/rule-versions", status_code=201, response_model=None)
def create_rule_version(
    data: RuleVersionCreate, user: User = Depends(rule_roles), db: Session = Depends(get_db)
) -> RuleVersion:
    get_or_error(db, BenefitRule, data.rule_id, "RULE_NOT_FOUND")
    latest = db.scalar(
        select(func.max(RuleVersion.version_no)).where(RuleVersion.rule_id == data.rule_id)
    )
    if data.version_no != (latest or 0) + 1:
        raise DomainError(
            "RULE_VERSION_SEQUENCE_INVALID",
            "Rule version number must increase sequentially",
            422,
        )
    if data.status in {RuleStatus.ACTIVE, RuleStatus.APPROVED}:
        raise DomainError(
            "INVALID_RULE_STATE_TRANSITION",
            "Rule versions cannot be created active or approved",
            422,
        )
    if (
        data.source_type is RuleSourceType.AI_EXTRACTED
        and data.status is not RuleStatus.AI_EXTRACTED
    ):
        raise DomainError(
            "INVALID_RULE_STATE_TRANSITION", "AI extracted rules must begin in AI_EXTRACTED", 422
        )
    obj = RuleVersion(**data.model_dump(), created_by=user.user_id)
    db.add(obj)
    commit(db, "RULE_VERSION_CONFLICT")
    db.refresh(obj)
    return obj


@router.post("/rule-conditions", status_code=201, response_model=None)
def create_condition(
    data: ConditionCreate, _: User = Depends(rule_roles), db: Session = Depends(get_db)
) -> RuleCondition:
    version = get_or_error(db, RuleVersion, data.rule_version_id, "RULE_VERSION_NOT_FOUND")
    if version.status not in {
        RuleStatus.DRAFT,
        RuleStatus.AI_EXTRACTED,
        RuleStatus.REVIEW_REQUIRED,
    }:
        raise DomainError("RULE_VERSION_IMMUTABLE", "Rule version is not editable", 409)
    obj = RuleCondition(**data.model_dump())
    db.add(obj)
    commit(db, "RULE_CONDITION_CONFLICT")
    db.refresh(obj)
    return obj


@router.post("/rule-clauses", status_code=201, response_model=None)
def link_rule_clause(
    data: RuleClauseCreate, _: User = Depends(rule_roles), db: Session = Depends(get_db)
) -> BenefitRuleClause:
    rule = get_or_error(db, BenefitRule, data.rule_id, "RULE_NOT_FOUND")
    clause = get_or_error(db, PolicyClause, data.clause_id, "POLICY_CLAUSE_NOT_FOUND")
    if rule.policy_version_id != clause.policy_version_id:
        raise DomainError(
            "RULE_CLAUSE_POLICY_MISMATCH", "Rule evidence must belong to its policy version", 422
        )
    obj = BenefitRuleClause(**data.model_dump())
    db.add(obj)
    commit(db, "RULE_CLAUSE_CONFLICT")
    db.refresh(obj)
    return obj
