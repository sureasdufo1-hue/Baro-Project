from uuid import UUID

from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session

from domain.audit.models import AuditEventType, AuditLog
from domain.policy.models import InsuranceCompany, MasterStatus
from domain.user.models import User, UserRole


def login_as(
    client: TestClient,
    db: Session,
    registration_payload: dict[str, object],
    role: UserRole,
) -> None:
    assert client.post("/api/auth/register", json=registration_payload).status_code == 201
    user = db.scalar(select(User).where(User.email == registration_payload["email"]))
    assert user is not None
    user.role = role
    db.commit()
    assert (
        client.post(
            "/api/auth/login",
            json={
                "email": registration_payload["email"],
                "password": registration_payload["password"],
            },
        ).status_code
        == 200
    )


def test_policy_editor_builds_versioned_insurance_knowledge_chain(
    client: TestClient, db_session: Session, registration_payload: dict[str, object]
) -> None:
    login_as(client, db_session, registration_payload, UserRole.POLICY_EDITOR)
    company = client.post(
        "/api/admin/insurance-companies",
        json={
            "company_code": "TEST_CO",
            "company_name": "TEST Insurance Company",
            "company_type": "TEST",
        },
    )
    assert company.status_code == 201
    company_id = company.json()["company_id"]
    duplicate = client.post(
        "/api/admin/insurance-companies",
        json={
            "company_code": "TEST_CO",
            "company_name": "Duplicate",
            "company_type": "TEST",
        },
    )
    assert duplicate.status_code == 409
    product = client.post(
        "/api/admin/insurance-products",
        json={
            "company_id": company_id,
            "product_code": "TEST_PRODUCT",
            "product_name": "TEST Health Product",
            "insurance_type": "THIRD_PARTY",
        },
    )
    assert product.status_code == 201
    product_version = client.post(
        "/api/admin/product-versions",
        json={
            "product_id": product.json()["product_id"],
            "version_name": "TEST_V1",
            "sale_start_date": "2026-01-01",
            "sale_end_date": "2026-12-31",
        },
    )
    assert product_version.status_code == 201
    policy = client.post(
        "/api/admin/policies",
        json={
            "product_version_id": product_version.json()["product_version_id"],
            "policy_name": "TEST Policy",
            "policy_type": "GENERAL",
        },
    )
    assert policy.status_code == 201
    version = client.post(
        "/api/admin/policy-versions",
        json={
            "policy_id": policy.json()["policy_id"],
            "version_code": "TEST_POLICY_V1",
            "effective_from": "2026-01-01",
        },
    )
    assert version.status_code == 201
    clause = client.post(
        "/api/admin/policy-clauses",
        json={
            "policy_version_id": version.json()["policy_version_id"],
            "article_number": "TEST-1",
            "clause_text": "TEST FIXTURE clause without insurance payment conditions.",
        },
    )
    assert clause.status_code == 201
    coverage = client.post(
        "/api/admin/coverages",
        json={
            "standard_code": "TEST_COVERAGE",
            "coverage_name": "TEST Coverage",
            "coverage_category": "TEST",
            "insurance_type": "THIRD_PARTY",
        },
    )
    assert coverage.status_code == 201
    alias = client.post(
        "/api/admin/coverage-aliases",
        json={
            "coverage_id": coverage.json()["coverage_id"],
            "company_id": company_id,
            "alias_name": "TEST Alias",
            "normalized_name": "test alias",
        },
    )
    assert alias.status_code == 201
    events = set(db_session.scalars(select(AuditLog.event_type)))
    assert AuditEventType.POLICY_VERSION_CREATE in events
    assert AuditEventType.COVERAGE_CREATE in events


def test_rule_editor_stores_rule_but_cannot_activate_ai_rule(
    client: TestClient, db_session: Session, registration_payload: dict[str, object]
) -> None:
    login_as(client, db_session, registration_payload, UserRole.SYSTEM_ADMIN)
    company = client.post(
        "/api/admin/insurance-companies",
        json={"company_code": "RCO", "company_name": "TEST Rule Company", "company_type": "TEST"},
    ).json()
    product = client.post(
        "/api/admin/insurance-products",
        json={
            "company_id": company["company_id"],
            "product_code": "RP",
            "product_name": "TEST Rule Product",
            "insurance_type": "THIRD_PARTY",
        },
    ).json()
    pv = client.post(
        "/api/admin/product-versions",
        json={"product_id": product["product_id"], "version_name": "V1"},
    ).json()
    policy = client.post(
        "/api/admin/policies",
        json={
            "product_version_id": pv["product_version_id"],
            "policy_name": "TEST Rule Policy",
            "policy_type": "GENERAL",
        },
    ).json()
    policy_version = client.post(
        "/api/admin/policy-versions",
        json={
            "policy_id": policy["policy_id"],
            "version_code": "V1",
            "effective_from": "2026-01-01",
        },
    ).json()
    clause = client.post(
        "/api/admin/policy-clauses",
        json={
            "policy_version_id": policy_version["policy_version_id"],
            "clause_text": "TEST evidence only",
        },
    ).json()
    coverage = client.post(
        "/api/admin/coverages",
        json={
            "standard_code": "RULE_TEST",
            "coverage_name": "TEST Rule Coverage",
            "coverage_category": "TEST",
            "insurance_type": "THIRD_PARTY",
        },
    ).json()
    rule = client.post(
        "/api/admin/rules",
        json={
            "coverage_id": coverage["coverage_id"],
            "policy_version_id": policy_version["policy_version_id"],
            "rule_name": "TEST empty rule",
            "rule_type": "ELIGIBILITY",
        },
    )
    assert rule.status_code == 201
    rejected = client.post(
        "/api/admin/rule-versions",
        json={
            "rule_id": rule.json()["rule_id"],
            "version_no": 1,
            "rule_definition": {"conditions": []},
            "source_type": "AI_EXTRACTED",
            "status": "ACTIVE",
        },
    )
    assert rejected.status_code == 422
    created = client.post(
        "/api/admin/rule-versions",
        json={
            "rule_id": rule.json()["rule_id"],
            "version_no": 1,
            "rule_definition": {"conditions": []},
            "source_type": "AI_EXTRACTED",
            "status": "AI_EXTRACTED",
        },
    )
    assert created.status_code == 201
    condition = client.post(
        "/api/admin/rule-conditions",
        json={
            "rule_version_id": created.json()["rule_version_id"],
            "sequence_no": 1,
            "fact_path": "test.fixture",
            "operator": "EXISTS",
        },
    )
    assert condition.status_code == 201
    link = client.post(
        "/api/admin/rule-clauses",
        json={"rule_id": rule.json()["rule_id"], "clause_id": clause["clause_id"]},
    )
    assert link.status_code == 201


def test_user_cannot_mutate_insurance_master(
    client: TestClient, db_session: Session, registration_payload: dict[str, object]
) -> None:
    login_as(client, db_session, registration_payload, UserRole.USER)
    assert (
        client.post(
            "/api/admin/insurance-companies",
            json={"company_code": "NO", "company_name": "Denied", "company_type": "TEST"},
        ).status_code
        == 403
    )


def test_company_is_inactivated_not_deleted(
    client: TestClient, db_session: Session, registration_payload: dict[str, object]
) -> None:
    login_as(client, db_session, registration_payload, UserRole.SYSTEM_ADMIN)
    company = client.post(
        "/api/admin/insurance-companies",
        json={
            "company_code": "INACTIVE_TEST",
            "company_name": "TEST Company",
            "company_type": "TEST",
        },
    ).json()
    response = client.patch(
        f"/api/admin/insurance-companies/{company['company_id']}", json={"status": "INACTIVE"}
    )
    assert response.status_code == 200
    stored = db_session.get(InsuranceCompany, UUID(company["company_id"]))
    assert stored is not None and stored.status is MasterStatus.INACTIVE
