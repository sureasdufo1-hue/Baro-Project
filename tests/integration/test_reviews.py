import uuid
from pathlib import Path
from uuid import UUID

from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session

from apps.api.app.dependencies import (
    get_extraction_provider,
    get_malware_scanner,
    get_object_storage,
    get_ocr_provider,
    get_ocr_queue,
)
from domain.audit.models import AuditEventType, AuditLog
from domain.claim.models import Claim, ClaimStatus
from domain.fact.models import OCRResult
from domain.fact.service import process_ocr
from domain.review.models import Review, ReviewStatus
from domain.user.models import User, UserRole
from infrastructure.ai.provider import DevelopmentExtractionProvider
from infrastructure.ocr.provider import DevelopmentOCRProvider
from infrastructure.security.malware import ScanResult
from infrastructure.storage.object_storage import LocalPrivateStorage
from tests.integration.test_claims import create_contract, create_disease_claim
from tests.integration.test_documents import FixedScanner
from tests.integration.test_insurance_master import login_as
from tests.integration.test_ocr_fact_flow import CapturingQueue


def credentials(email: str) -> dict[str, object]:
    return {
        "email": email,
        "password": "ValidPassword!123",
        "display_name": email.split("@")[0],
        "phone": None,
        "consents": [
            {"consent_type": "SERVICE_TERMS", "consent_version": "1", "agreed": True},
            {"consent_type": "PRIVACY", "consent_version": "1", "agreed": True},
            {
                "consent_type": "SENSITIVE_INFORMATION",
                "consent_version": "1",
                "agreed": True,
            },
            {"consent_type": "AI_PROCESSING", "consent_version": "1", "agreed": True},
        ],
    }


def test_review_assignment_approve_complete_and_authorization(
    client: TestClient, db_session: Session
) -> None:
    contract_id = create_contract(client, db_session, "review-owner@example.com")
    payload = create_disease_claim(client, contract_id)
    claim = db_session.get(Claim, uuid.UUID(payload["claim_id"]))
    assert claim is not None
    claim.status = ClaimStatus.MANUAL_REVIEW
    db_session.commit()

    client.post("/api/auth/logout")
    admin_data = credentials("review-admin@example.com")
    login_as(client, db_session, admin_data, UserRole.SYSTEM_ADMIN)
    created = client.post(
        "/api/reviews",
        json={
            "claim_id": payload["claim_id"],
            "review_type": "GENERAL_CLAIM_REVIEW",
            "reason": "Automatic decision is unresolved",
        },
    )
    assert created.status_code == 201
    review_id = created.json()["review_id"]

    client.post("/api/auth/logout")
    adjuster_data = credentials("assigned-adjuster@example.com")
    login_as(client, db_session, adjuster_data, UserRole.ADJUSTER)
    adjuster = db_session.scalar(select(User).where(User.email == adjuster_data["email"]))
    assert adjuster is not None
    assert client.post(f"/api/reviews/{review_id}/accept").status_code == 403

    client.post("/api/auth/logout")
    client.post(
        "/api/auth/login",
        json={"email": admin_data["email"], "password": admin_data["password"]},
    )
    assigned = client.post(
        f"/api/reviews/{review_id}/assign",
        json={"reviewer_user_id": str(adjuster.user_id)},
    )
    assert assigned.status_code == 200

    client.post("/api/auth/logout")
    client.post(
        "/api/auth/login",
        json={"email": adjuster_data["email"], "password": adjuster_data["password"]},
    )
    assert client.post(f"/api/reviews/{review_id}/accept").status_code == 200
    assert client.get(f"/api/reviews/{review_id}/context").status_code == 200
    assert (
        client.post(
            f"/api/reviews/{review_id}/approve",
            json={"opinion": "Reviewed evidence supports the result"},
        ).status_code
        == 200
    )
    assert client.post(f"/api/reviews/{review_id}/complete").status_code == 200
    review = db_session.get(Review, uuid.UUID(review_id))
    db_session.refresh(claim)
    assert review is not None and review.review_status is ReviewStatus.COMPLETED
    assert claim.status is ClaimStatus.COMPLETED
    assert (
        db_session.scalar(
            select(AuditLog).where(AuditLog.event_type == AuditEventType.REVIEW_APPROVE)
        )
        is not None
    )


def test_additional_document_submission_resumes_existing_review(
    client: TestClient, db_session: Session, tmp_path: Path
) -> None:
    owner_email = "additional-owner@example.com"
    contract_id = create_contract(client, db_session, owner_email)
    payload = create_disease_claim(client, contract_id)
    claim = db_session.get(Claim, uuid.UUID(payload["claim_id"]))
    assert claim is not None
    claim.status = ClaimStatus.MANUAL_REVIEW
    db_session.commit()

    client.post("/api/auth/logout")
    admin_data = credentials("additional-admin@example.com")
    login_as(client, db_session, admin_data, UserRole.SYSTEM_ADMIN)
    created = client.post(
        "/api/reviews",
        json={
            "claim_id": payload["claim_id"],
            "review_type": "GENERAL_CLAIM_REVIEW",
            "reason": "TEST additional evidence required",
        },
    )
    review_id = created.json()["review_id"]
    client.post("/api/auth/logout")
    adjuster_data = credentials("additional-adjuster@example.com")
    login_as(client, db_session, adjuster_data, UserRole.ADJUSTER)
    adjuster = db_session.scalar(select(User).where(User.email == adjuster_data["email"]))
    assert adjuster is not None
    client.post("/api/auth/logout")
    client.post(
        "/api/auth/login", json={"email": admin_data["email"], "password": admin_data["password"]}
    )
    client.post(
        f"/api/reviews/{review_id}/assign",
        json={"reviewer_user_id": str(adjuster.user_id)},
    )
    client.post("/api/auth/logout")
    client.post(
        "/api/auth/login",
        json={"email": adjuster_data["email"], "password": adjuster_data["password"]},
    )
    client.post(f"/api/reviews/{review_id}/accept")
    requested = client.post(
        f"/api/reviews/{review_id}/request-documents",
        json={
            "requested_document_type": "DIAGNOSIS_CERTIFICATE",
            "requested_fact_type": "DIAGNOSIS_CODE",
            "reason": "TEST missing diagnosis evidence",
            "user_message": "Upload a TEST diagnosis certificate",
        },
    )
    assert requested.status_code == 200
    request_id = requested.json()["request_id"]

    storage = LocalPrivateStorage(tmp_path / "additional-private")
    queue = CapturingQueue()
    client.app.dependency_overrides[get_object_storage] = lambda: storage
    client.app.dependency_overrides[get_malware_scanner] = lambda: FixedScanner(ScanResult.CLEAN)
    client.app.dependency_overrides[get_ocr_provider] = DevelopmentOCRProvider
    client.app.dependency_overrides[get_extraction_provider] = DevelopmentExtractionProvider
    client.app.dependency_overrides[get_ocr_queue] = lambda: queue
    client.post("/api/auth/logout")
    client.post(
        "/api/auth/login",
        json={"email": owner_email, "password": "correct-horse-battery-staple"},
    )
    content = b"%PDF-1.4\nFACT:DIAGNOSIS_CODE=I21.9|0.99\n%%EOF"
    upload = client.post(
        f"/api/claims/{claim.claim_id}/documents",
        data={
            "documentType": "DIAGNOSIS_CERTIFICATE",
            "additionalDocumentRequestId": request_id,
        },
        files={"file": ("test-additional.pdf", content, "application/pdf")},
    )
    assert upload.status_code == 201
    assert upload.json()["submission_round"] == 1
    assert client.post(f"/api/claims/{claim.claim_id}/analysis").status_code == 202
    result = db_session.get(OCRResult, UUID(str(queue.ids[0])))
    assert result is not None
    facts = process_ocr(
        db_session, result, storage, DevelopmentOCRProvider(), DevelopmentExtractionProvider()
    )
    db_session.commit()
    assert len(facts) == 1
    assert client.post(f"/api/facts/{facts[0].extracted_fact_id}/confirm").status_code == 200
    resumed = client.post(
        f"/api/claims/{claim.claim_id}/additional-document-requests/{request_id}/resume"
    )
    assert resumed.status_code == 200
    assert resumed.json()["review_status"] == ReviewStatus.IN_PROGRESS
    assert resumed.json()["request_status"] == "RESOLVED"
    db_session.refresh(claim)
    assert claim.status is ClaimStatus.MANUAL_REVIEW


def test_adjuster_listing_requires_system_admin(client: TestClient, db_session: Session) -> None:
    login_as(client, db_session, credentials("adjuster-roster@example.com"), UserRole.ADJUSTER)
    forbidden = client.get("/api/admin/adjusters")
    assert forbidden.status_code == 403

    client.post("/api/auth/logout")
    login_as(client, db_session, credentials("review-admin-2@example.com"), UserRole.SYSTEM_ADMIN)
    listed = client.get("/api/admin/adjusters")
    assert listed.status_code == 200
    roster = {item["email"]: item for item in listed.json()}
    assert "adjuster-roster@example.com" in roster
    assert UUID(roster["adjuster-roster@example.com"]["user_id"])
