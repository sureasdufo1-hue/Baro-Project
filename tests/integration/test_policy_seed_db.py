import shutil
import sqlite3
from pathlib import Path

from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import Session

from apps.api.app.main import app
from apps.api.app.routes import policy_db
from domain.audit.models import AuditEventType, AuditLog, AuditResult
from domain.user.models import UserRole
from infrastructure.database.policy_seed import PolicySeedRepository
from tests.integration.test_insurance_master import login_as

ROOT = Path(__file__).resolve().parents[2]


def test_policy_database_health_and_catalog(client: TestClient) -> None:
    health = client.get("/api/health/db")
    assert health.status_code == 200
    assert health.json()["schema"] == "ok" and health.json()["seed_loaded"] is True
    companies = client.get("/api/policies/companies").json()
    products = client.get("/api/policies/products").json()
    assert len(companies) == 1 and len(products) == 3
    assert {p["product_code"] for p in products} == {"PROMY-AUTO", "31201", "30944"}


def test_product_version_document_coverage_read_apis(client: TestClient) -> None:
    products = client.get("/api/policies/products").json()
    cancer = next(p for p in products if p["product_code"] == "31201")
    assert client.get(f"/api/policies/products/{cancer['id']}").status_code == 200
    versions = client.get(f"/api/policies/products/{cancer['id']}/versions").json()
    documents = client.get(f"/api/policies/versions/{versions[0]['id']}/documents").json()
    coverages = client.get(f"/api/policies/versions/{versions[0]['id']}/coverages").json()
    assert {d["document_type"] for d in documents} == {
        "SUMMARY",
        "BUSINESS_METHOD",
        "POLICY",
    }
    assert len(coverages) == 2
    detail = client.get(f"/api/policies/coverages/{coverages[0]['id']}/rule").json()
    assert detail["rule_status"] == "OFFICIAL_CROSSCHECKED"


def test_version_resolver_is_deterministic(client: TestClient) -> None:
    product = next(
        p for p in client.get("/api/policies/products").json() if p["product_code"] == "31201"
    )
    resolved = client.get(
        f"/api/policies/products/{product['id']}/versions/resolve",
        params={"contract_date": "2026-08-01"},
    ).json()
    missing = client.get(
        f"/api/policies/products/{product['id']}/versions/resolve",
        params={"contract_date": "2025-01-01"},
    ).json()
    assert resolved["status"] == "RESOLVED"
    assert missing["status"] == "NOT_FOUND"


def test_auto_promotion_claim_and_evidence(client: TestClient) -> None:
    coverages = client.get("/api/policies/products").json()
    auto_product = next(p for p in coverages if p["product_code"] == "PROMY-AUTO")
    version = client.get(f"/api/policies/products/{auto_product['id']}/versions").json()[0]
    coverage = client.get(f"/api/policies/versions/{version['id']}/coverages").json()[0]
    gate = client.get(f"/api/policies/coverages/{coverage['id']}/promotion-status").json()
    assert gate["status"] == "PASS"
    result = client.post(
        "/api/policies/claims/calculate",
        json={
            "coverage_id": coverage["id"],
            "facts": {
                "vehicle_damage": 5000000,
                "expenses": 0,
                "deductible": 200000,
                "insured_amount": 20000000,
            },
        },
    ).json()
    assert result["status"] == "PAYABLE" and result["final_amount"] == 4800000
    assert result["evidence"] and result["evidence"][0]["document_type"] == "POLICY"


def test_cancer_claim_fails_closed(client: TestClient) -> None:
    product = next(
        p for p in client.get("/api/policies/products").json() if p["product_code"] == "31201"
    )
    version = client.get(f"/api/policies/products/{product['id']}/versions").json()[0]
    coverage = client.get(f"/api/policies/versions/{version['id']}/coverages").json()[0]
    result = client.post(
        "/api/policies/claims/calculate",
        json={"coverage_id": coverage["id"], "facts": {"insured_amount": 20000000}},
    ).json()
    assert result["status"] == "HUMAN_REVIEW_REQUIRED"
    assert result["final_amount"] is None
    assert "RULE_NOT_VERIFIED_POLICY" in result["promotion_gate"]["reasons"]
    assert "KCD_OR_DISEASE_DEFINITION_NOT_VERIFIED" in result["promotion_gate"]["reasons"]


def test_admin_policy_summary_uses_seed(client: TestClient) -> None:
    summary = client.get("/api/admin/policy-db/summary").json()
    assert summary == {
        "companies": 1,
        "products": 3,
        "versions": 3,
        "documents": 5,
        "coverages": 3,
        "verified_policy": 1,
        "official_crosschecked": 2,
        "human_review_required": 2,
    }


def test_31201_policy_is_acquired_but_not_auto_promoted(client: TestClient) -> None:
    product = next(
        p for p in client.get("/api/policies/products").json() if p["product_code"] == "31201"
    )
    version = client.get(f"/api/policies/products/{product['id']}/versions").json()[0]
    documents = client.get(f"/api/policies/versions/{version['id']}/documents").json()
    assert "POLICY" in {document["document_type"] for document in documents}
    coverage = client.get(f"/api/policies/versions/{version['id']}/coverages").json()[0]
    rule = client.get(f"/api/policies/coverages/{coverage['id']}/rule").json()
    assert rule["rule_status"] == "OFFICIAL_CROSSCHECKED"
    assert rule["promotion_gate"]["status"] == "FAIL"
    assert any(
        code["source_status"] == "POLICY_EXTRACTED_PENDING_REVIEW" for code in rule["disease_codes"]
    )


def test_policy_verification_review_context_requires_authorized_role(
    client: TestClient,
    db_session: Session,
    registration_payload: dict[str, object],
) -> None:
    assert client.get("/api/admin/policy-db/verification-queue").status_code == 401
    login_as(client, db_session, registration_payload, UserRole.POLICY_EDITOR)
    queue = client.get("/api/admin/policy-db/verification-queue")
    assert queue.status_code == 200
    pending = next(item for item in queue.json() if item["coverage_id"] == 2)
    assert pending["pending"] == 7 and pending["eligible_for_promotion"] is False
    context = client.get("/api/admin/policy-db/coverages/2/verification-context")
    assert context.status_code == 200
    assert context.json()["verification"]["rule_status"] == "OFFICIAL_CROSSCHECKED"


def test_policy_verification_changes_are_audited_without_mutating_runtime_db(
    client: TestClient,
    db_session: Session,
    registration_payload: dict[str, object],
    tmp_path: Path,
) -> None:
    database = tmp_path / "policy-audit.db"
    shutil.copy2(ROOT / "dbins_poc" / "runtime" / "dbins_policy.sqlite3", database)
    with sqlite3.connect(database) as connection:
        connection.executescript(
            (ROOT / "dbins_poc" / "migrations" / "003_policy_verification_reviews.sql").read_text(
                encoding="utf-8"
            )
        )
    engine = create_engine(f"sqlite:///{database}")
    connection = engine.connect()
    repository = PolicySeedRepository(connection)
    app.dependency_overrides[policy_db.repository] = lambda: repository
    try:
        login_as(client, db_session, registration_payload, UserRole.RULE_APPROVER)
        reviewed = client.put(
            "/api/admin/policy-db/coverages/2/verification/PRODUCT_CODE_MAPPING",
            json={"status": "APPROVED", "reason": "fixture source mapping checked"},
        )
        assert reviewed.status_code == 200
        blocked = client.post(
            "/api/admin/policy-db/coverages/2/promote",
            json={"reason": "fixture premature promotion"},
        )
        assert blocked.status_code == 409
        logs = list(
            db_session.scalars(
                select(AuditLog).where(
                    AuditLog.event_type.in_(
                        [
                            AuditEventType.POLICY_VERIFICATION_REVIEW,
                            AuditEventType.POLICY_VERIFICATION_PROMOTE,
                        ]
                    )
                )
            )
        )
        assert {(log.event_type, log.result) for log in logs} == {
            (AuditEventType.POLICY_VERIFICATION_REVIEW, AuditResult.SUCCESS),
            (AuditEventType.POLICY_VERIFICATION_PROMOTE, AuditResult.FAILURE),
        }
    finally:
        app.dependency_overrides.pop(policy_db.repository, None)
        connection.close()
        engine.dispose()
