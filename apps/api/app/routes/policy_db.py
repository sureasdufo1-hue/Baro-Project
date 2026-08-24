from datetime import date
from typing import Any

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field
from sqlalchemy.engine import Connection
from sqlalchemy.orm import Session

from apps.api.app.audit import record_audit
from apps.api.app.dependencies import require_role
from domain.audit.models import AuditEventType, AuditResult
from domain.user.models import User, UserRole
from infrastructure.database.policy_seed import PolicySeedRepository, get_policy_connection
from infrastructure.database.session import get_db
from shared.errors import DomainError

router = APIRouter(prefix="/api/policies", tags=["policy-database"])
admin_router = APIRouter(prefix="/api/admin/policy-db", tags=["policy-database"])
health_router = APIRouter(prefix="/api/health", tags=["health"])


def repository(connection: Connection = Depends(get_policy_connection)) -> PolicySeedRepository:
    return PolicySeedRepository(connection)


def required(value: dict[str, Any] | None, code: str) -> dict[str, Any]:
    if value is None:
        raise DomainError(code, "Policy database record was not found", 404)
    return value


@health_router.get("/db")
def database_health(repo: PolicySeedRepository = Depends(repository)) -> dict[str, Any]:
    return repo.health()


@router.get("/companies")
def companies(repo: PolicySeedRepository = Depends(repository)) -> list[dict[str, Any]]:
    return repo.companies()


@router.get("/companies/{company_id}/products")
def company_products(
    company_id: int, repo: PolicySeedRepository = Depends(repository)
) -> list[dict[str, Any]]:
    return repo.products(company_id)


@router.get("/products")
def products(repo: PolicySeedRepository = Depends(repository)) -> list[dict[str, Any]]:
    return repo.products()


@router.get("/products/{product_id}")
def product(product_id: int, repo: PolicySeedRepository = Depends(repository)) -> dict[str, Any]:
    return required(repo.product(product_id), "POLICY_PRODUCT_NOT_FOUND")


@router.get("/products/{product_id}/versions")
def versions(
    product_id: int, repo: PolicySeedRepository = Depends(repository)
) -> list[dict[str, Any]]:
    required(repo.product(product_id), "POLICY_PRODUCT_NOT_FOUND")
    return repo.versions(product_id)


@router.get("/products/{product_id}/versions/resolve")
def resolve_version(
    product_id: int, contract_date: date, repo: PolicySeedRepository = Depends(repository)
) -> dict[str, Any]:
    required(repo.product(product_id), "POLICY_PRODUCT_NOT_FOUND")
    return repo.resolve_version(product_id, contract_date)


@router.get("/versions/{version_id}")
def version(version_id: int, repo: PolicySeedRepository = Depends(repository)) -> dict[str, Any]:
    return required(repo.version(version_id), "POLICY_VERSION_NOT_FOUND")


@router.get("/versions/{version_id}/documents")
def documents(
    version_id: int, repo: PolicySeedRepository = Depends(repository)
) -> list[dict[str, Any]]:
    required(repo.version(version_id), "POLICY_VERSION_NOT_FOUND")
    return repo.documents(version_id)


@router.get("/versions/{version_id}/coverages")
def version_coverages(
    version_id: int, repo: PolicySeedRepository = Depends(repository)
) -> list[dict[str, Any]]:
    required(repo.version(version_id), "POLICY_VERSION_NOT_FOUND")
    return repo.coverages(version_id)


@router.get("/coverages/{coverage_id}")
def coverage(coverage_id: int, repo: PolicySeedRepository = Depends(repository)) -> dict[str, Any]:
    return required(repo.coverage(coverage_id), "COVERAGE_NOT_FOUND")


@router.get("/coverages/{coverage_id}/rule")
def rule(coverage_id: int, repo: PolicySeedRepository = Depends(repository)) -> dict[str, Any]:
    return required(repo.rule(coverage_id), "COVERAGE_NOT_FOUND")


@router.get("/coverages/{coverage_id}/evidence")
def evidence(
    coverage_id: int, repo: PolicySeedRepository = Depends(repository)
) -> list[dict[str, Any]]:
    required(repo.coverage(coverage_id), "COVERAGE_NOT_FOUND")
    return repo.evidence(coverage_id)


@router.get("/coverages/{coverage_id}/promotion-status")
def promotion_status(
    coverage_id: int, repo: PolicySeedRepository = Depends(repository)
) -> dict[str, Any]:
    return required(repo.promotion_gate(coverage_id), "COVERAGE_NOT_FOUND")


class PolicyClaimRequest(BaseModel):
    coverage_id: int
    facts: dict[str, Any] = Field(default_factory=dict)


@router.post("/claims/calculate")
def calculate(
    payload: PolicyClaimRequest, repo: PolicySeedRepository = Depends(repository)
) -> dict[str, Any]:
    return repo.calculate(payload.coverage_id, payload.facts)


@admin_router.get("/summary")
def summary(repo: PolicySeedRepository = Depends(repository)) -> dict[str, int]:
    return repo.summary()


review_roles = require_role(UserRole.POLICY_EDITOR, UserRole.RULE_APPROVER, UserRole.SYSTEM_ADMIN)
approval_roles = require_role(UserRole.RULE_APPROVER, UserRole.SYSTEM_ADMIN)


class VerificationCheckRequest(BaseModel):
    status: str
    reason: str = Field(min_length=3, max_length=2000)


class PromotionRequest(BaseModel):
    reason: str = Field(min_length=3, max_length=2000)


@admin_router.get("/verification-queue")
def verification_queue(
    _: User = Depends(review_roles),
    repo: PolicySeedRepository = Depends(repository),
) -> list[dict[str, Any]]:
    return repo.verification_queue()


@admin_router.get("/coverages/{coverage_id}/verification-context")
def verification_context(
    coverage_id: int,
    _: User = Depends(review_roles),
    repo: PolicySeedRepository = Depends(repository),
) -> dict[str, Any]:
    return required(repo.verification_context(coverage_id), "COVERAGE_NOT_FOUND")


@admin_router.get("/coverages/{coverage_id}/verification")
def verification_status(
    coverage_id: int,
    _: User = Depends(review_roles),
    repo: PolicySeedRepository = Depends(repository),
) -> dict[str, Any]:
    return required(repo.verification_status(coverage_id), "COVERAGE_NOT_FOUND")


@admin_router.post("/coverages/{coverage_id}/verification", status_code=201)
def initialize_verification(
    coverage_id: int,
    _: User = Depends(review_roles),
    repo: PolicySeedRepository = Depends(repository),
) -> dict[str, Any]:
    return required(repo.initialize_verification(coverage_id), "COVERAGE_NOT_FOUND")


@admin_router.put("/coverages/{coverage_id}/verification/{check_code}")
def review_verification_check(
    coverage_id: int,
    check_code: str,
    payload: VerificationCheckRequest,
    request: Request,
    user: User = Depends(approval_roles),
    db: Session = Depends(get_db),
    repo: PolicySeedRepository = Depends(repository),
) -> dict[str, Any]:
    before = repo.verification_status(coverage_id)
    try:
        result = repo.review_check(
            coverage_id, check_code, payload.status, str(user.user_id), payload.reason
        )
    except ValueError as exc:
        record_policy_verification_audit(
            db,
            request,
            user,
            coverage_id,
            AuditEventType.POLICY_VERIFICATION_REVIEW,
            AuditResult.FAILURE,
            before,
            {"check_code": check_code, "status": payload.status, "error": str(exc)},
        )
        db.commit()
        raise DomainError("POLICY_VERIFICATION_INVALID", str(exc), 422) from None
    record_policy_verification_audit(
        db,
        request,
        user,
        coverage_id,
        AuditEventType.POLICY_VERIFICATION_REVIEW,
        AuditResult.SUCCESS,
        before,
        {"check_code": check_code, "status": payload.status, "reason": payload.reason},
    )
    db.commit()
    return required(result, "COVERAGE_NOT_FOUND")


@admin_router.post("/coverages/{coverage_id}/promote")
def promote_coverage(
    coverage_id: int,
    payload: PromotionRequest,
    request: Request,
    user: User = Depends(approval_roles),
    db: Session = Depends(get_db),
    repo: PolicySeedRepository = Depends(repository),
) -> dict[str, Any]:
    before = repo.verification_status(coverage_id)
    try:
        result = repo.promote_verified_policy(coverage_id, str(user.user_id), payload.reason)
    except ValueError as exc:
        record_policy_verification_audit(
            db,
            request,
            user,
            coverage_id,
            AuditEventType.POLICY_VERIFICATION_PROMOTE,
            AuditResult.FAILURE,
            before,
            {"reason": payload.reason, "error": str(exc)},
        )
        db.commit()
        raise DomainError("POLICY_PROMOTION_BLOCKED", str(exc), 409) from None
    record_policy_verification_audit(
        db,
        request,
        user,
        coverage_id,
        AuditEventType.POLICY_VERIFICATION_PROMOTE,
        AuditResult.SUCCESS,
        before,
        {"reason": payload.reason, "result": result},
    )
    db.commit()
    return result


def record_policy_verification_audit(
    db: Session,
    request: Request,
    user: User,
    coverage_id: int,
    event: AuditEventType,
    result: AuditResult,
    before: dict[str, Any] | None,
    after: dict[str, Any],
) -> None:
    record_audit(
        db,
        event_type=event,
        result=result,
        actor_user_id=user.user_id,
        object_type="PolicySeedCoverage",
        object_id=str(coverage_id),
        request_id=request.state.request_id,
        source_ip=request.client.host if request.client else None,
        before_value=before,
        after_value=after,
    )
