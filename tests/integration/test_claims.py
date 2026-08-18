from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session

from domain.audit.models import AuditEventType, AuditLog
from domain.policy.models import ProductVersion
from tests.integration.test_contracts import master_fixture, register_login


def create_contract(client: TestClient, db: Session, email: str) -> str:
    version = db.scalar(select(ProductVersion))
    if version is None:
        version, _ = master_fixture(db)
    register_login(client, email)
    insured = client.post(
        "/api/insureds", json={"name": "Claim Insured", "relationship_type": "SELF"}
    ).json()
    response = client.post(
        "/api/contracts",
        json={
            "insured_id": insured["insured_id"],
            "product_version_id": str(version.product_version_id),
            "coverages": [],
        },
    )
    assert response.status_code == 201
    return response.json()["contract_id"]


def create_disease_claim(client: TestClient, contract_id: str, title: str = "진단 Case") -> dict:
    response = client.post(
        "/api/claims",
        json={
            "contract_id": contract_id,
            "claim_type": "DISEASE",
            "title": title,
            "accident": {
                "diagnosis_date": "2026-07-10",
                "onset_date": "2026-07-09",
                "description": "사용자가 입력한 진단 정보",
            },
        },
    )
    assert response.status_code == 201
    return response.json()


def test_golden_claim_flow_list_update_transition_cancel_and_audit(
    client: TestClient, db_session: Session
) -> None:
    contract_id = create_contract(client, db_session, "claim-flow@example.com")
    claim = create_disease_claim(client, contract_id)
    claim_id = claim["claim_id"]
    assert claim["status"] == "DRAFT"
    assert claim["claim_number"].startswith("CLM-")
    assert claim["accident"]["diagnosis_date"] == "2026-07-10"

    assert client.patch(f"/api/claims/{claim_id}", json={"title": "수정 제목"}).status_code == 200
    accident = client.patch(f"/api/claims/{claim_id}/accident", json={"onset_date": "2026-07-08"})
    assert accident.status_code == 200
    assert accident.json()["onset_date"] == "2026-07-08"
    transitioned = client.post(
        f"/api/claims/{claim_id}/transitions",
        json={"action": "SUBMIT_ACCIDENT_INFORMATION"},
    )
    assert transitioned.status_code == 200
    assert transitioned.json()["status"] == "DOCUMENT_REQUIRED"
    assert client.get(f"/api/claims/{claim_id}").status_code == 200
    listed = client.get("/api/claims?status=DOCUMENT_REQUIRED").json()
    assert [item["claim_id"] for item in listed] == [claim_id]
    cancelled = client.post(f"/api/claims/{claim_id}/cancel")
    assert cancelled.status_code == 200
    assert cancelled.json()["status"] == "CANCELLED"
    assert (
        db_session.scalar(
            select(AuditLog).where(AuditLog.event_type == AuditEventType.CLAIM_CREATE)
        )
        is not None
    )
    assert (
        db_session.scalar(
            select(AuditLog).where(AuditLog.event_type == AuditEventType.CLAIM_STATUS_CHANGE)
        )
        is not None
    )


def test_injury_validation_and_invalid_transition(client: TestClient, db_session: Session) -> None:
    contract_id = create_contract(client, db_session, "injury@example.com")
    bad = client.post(
        "/api/claims",
        json={
            "contract_id": contract_id,
            "claim_type": "INJURY",
            "accident": {"description": "넘어짐"},
        },
    )
    assert bad.status_code == 422
    good = client.post(
        "/api/claims",
        json={
            "contract_id": contract_id,
            "claim_type": "INJURY",
            "accident": {
                "accident_date": "2026-08-01",
                "location": "서울",
                "description": "넘어짐",
            },
        },
    )
    assert good.status_code == 201
    claim_id = good.json()["claim_id"]
    assert client.post(f"/api/claims/{claim_id}/cancel").status_code == 200
    assert (
        client.post(
            f"/api/claims/{claim_id}/transitions", json={"action": "SUBMIT_ACCIDENT_INFORMATION"}
        ).status_code
        == 409
    )


def test_cross_user_claim_idor_and_list_isolation(client: TestClient, db_session: Session) -> None:
    contract_id = create_contract(client, db_session, "claim-owner@example.com")
    owner_claim = create_disease_claim(client, contract_id)
    client.post("/api/auth/logout")
    other_contract_id = create_contract(client, db_session, "claim-other@example.com")
    other_claim = create_disease_claim(client, other_contract_id, "Other")
    claim_id = owner_claim["claim_id"]
    assert client.get(f"/api/claims/{claim_id}").status_code == 403
    assert client.patch(f"/api/claims/{claim_id}", json={"title": "Attack"}).status_code == 403
    assert (
        client.patch(
            f"/api/claims/{claim_id}/accident", json={"diagnosis_date": "2026-01-01"}
        ).status_code
        == 403
    )
    assert client.post(f"/api/claims/{claim_id}/cancel").status_code == 403
    assert (
        client.post(
            "/api/claims",
            json={
                "contract_id": contract_id,
                "claim_type": "DISEASE",
                "accident": {"diagnosis_date": "2026-01-01"},
            },
        ).status_code
        == 403
    )
    assert [x["claim_id"] for x in client.get("/api/claims").json()] == [other_claim["claim_id"]]
