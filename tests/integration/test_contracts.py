from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session

from domain.audit.models import AuditEventType, AuditLog
from domain.policy.models import (
    Coverage,
    InsuranceCompany,
    InsuranceProduct,
    InsuranceType,
    ProductVersion,
)


def register_login(client: TestClient, email: str) -> None:
    payload = {
        "email": email,
        "password": "correct-horse-battery-staple",
        "display_name": "Contract User",
        "consents": [
            {"consent_type": "SERVICE_TERMS", "consent_version": "1.0", "agreed": True},
            {"consent_type": "PRIVACY", "consent_version": "1.0", "agreed": True},
        ],
    }
    assert client.post("/api/auth/register", json=payload).status_code == 201
    assert (
        client.post(
            "/api/auth/login", json={"email": email, "password": payload["password"]}
        ).status_code
        == 200
    )


def master_fixture(db: Session) -> tuple[ProductVersion, Coverage]:
    company = InsuranceCompany(
        company_code="CONTRACT_TEST_CO", company_name="TEST Contract Company", company_type="TEST"
    )
    db.add(company)
    db.flush()
    product = InsuranceProduct(
        company_id=company.company_id,
        product_code="CONTRACT_TEST_PRODUCT",
        product_name="TEST Contract Product",
        insurance_type=InsuranceType.THIRD_PARTY,
    )
    db.add(product)
    db.flush()
    version = ProductVersion(product_id=product.product_id, version_name="TEST_V1")
    coverage = Coverage(
        standard_code="CONTRACT_TEST_COVERAGE",
        coverage_name="TEST Coverage",
        coverage_category="TEST",
        insurance_type=InsuranceType.THIRD_PARTY,
    )
    db.add_all([version, coverage])
    db.commit()
    return version, coverage


def test_contract_golden_flow_and_money_audit(client: TestClient, db_session: Session) -> None:
    version, coverage = master_fixture(db_session)
    register_login(client, "contract-a@example.com")
    insured = client.post(
        "/api/insureds",
        json={
            "name": "Test Insured",
            "birth_date": "1990-01-01",
            "gender": "UNKNOWN",
            "relationship_type": "SELF",
        },
    )
    assert insured.status_code == 201
    contract = client.post(
        "/api/contracts",
        json={
            "insured_id": insured.json()["insured_id"],
            "product_version_id": str(version.product_version_id),
            "policy_number": "TEST-POLICY-001",
            "contract_date": "2026-01-01",
            "coverage_start_date": "2026-01-01",
            "coverage_end_date": "2046-01-01",
            "coverages": [
                {
                    "coverage_id": str(coverage.coverage_id),
                    "coverage_name_snapshot": "TEST 가입 당시 담보명",
                    "insured_amount": 30000000,
                    "coverage_start_date": "2026-01-01",
                    "coverage_end_date": "2046-01-01",
                }
            ],
        },
    )
    assert contract.status_code == 201
    contract_id = contract.json()["contract_id"]
    detail = client.get(f"/api/contracts/{contract_id}")
    assert detail.status_code == 200
    assert detail.json()["policy_version_id"] is None
    assert detail.json()["coverages"][0]["insured_amount"] == 30000000
    item_id = detail.json()["coverages"][0]["contract_coverage_id"]
    changed = client.patch(
        f"/api/contracts/{contract_id}/coverages/{item_id}", json={"insured_amount": 150000000}
    )
    assert changed.status_code == 200
    assert changed.json()["insured_amount"] == 150000000
    event = db_session.scalar(
        select(AuditLog).where(AuditLog.event_type == AuditEventType.CONTRACT_COVERAGE_MODIFY)
    )
    assert event is not None
    assert event.before_value["insured_amount"] == 30000000
    assert event.after_value["insured_amount"] == 150000000


def test_cross_user_contract_and_insured_access_is_denied(
    client: TestClient, db_session: Session
) -> None:
    version, coverage = master_fixture(db_session)
    register_login(client, "owner@example.com")
    insured = client.post(
        "/api/insureds", json={"name": "Owner Insured", "relationship_type": "SELF"}
    ).json()
    contract = client.post(
        "/api/contracts",
        json={
            "insured_id": insured["insured_id"],
            "product_version_id": str(version.product_version_id),
            "coverages": [],
        },
    ).json()
    client.post("/api/auth/logout")
    register_login(client, "attacker@example.com")
    contract_id = contract["contract_id"]
    assert client.get(f"/api/contracts/{contract_id}").status_code == 403
    assert (
        client.patch(
            f"/api/contracts/{contract_id}", json={"contract_status": "CANCELLED"}
        ).status_code
        == 403
    )
    assert (
        client.post(
            f"/api/contracts/{contract_id}/coverages",
            json={
                "coverage_id": str(coverage.coverage_id),
                "coverage_name_snapshot": "Attack",
                "insured_amount": 1,
            },
        ).status_code
        == 403
    )
    assert (
        client.post(
            "/api/contracts",
            json={
                "insured_id": insured["insured_id"],
                "product_version_id": str(version.product_version_id),
                "coverages": [],
            },
        ).status_code
        == 403
    )


def test_invalid_contract_values_are_rejected(client: TestClient, db_session: Session) -> None:
    version, coverage = master_fixture(db_session)
    register_login(client, "invalid@example.com")
    insured = client.post(
        "/api/insureds", json={"name": "Test", "relationship_type": "SELF"}
    ).json()
    bad_period = client.post(
        "/api/contracts",
        json={
            "insured_id": insured["insured_id"],
            "product_version_id": str(version.product_version_id),
            "coverage_start_date": "2026-12-31",
            "coverage_end_date": "2026-01-01",
        },
    )
    assert bad_period.status_code == 422
    bad_money = client.post(
        "/api/contracts",
        json={
            "insured_id": insured["insured_id"],
            "product_version_id": str(version.product_version_id),
            "coverages": [
                {
                    "coverage_id": str(coverage.coverage_id),
                    "coverage_name_snapshot": "TEST",
                    "insured_amount": -1,
                }
            ],
        },
    )
    assert bad_money.status_code == 422
