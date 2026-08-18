from pathlib import Path
from uuid import UUID

from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session

from apps.api.app.dependencies import get_malware_scanner, get_object_storage
from domain.audit.models import AuditEventType, AuditLog
from domain.document.models import MedicalDocument
from infrastructure.security.malware import ScanResult
from infrastructure.storage.object_storage import LocalPrivateStorage
from shared.errors import DomainError
from tests.integration.test_claims import create_contract, create_disease_claim


class FixedScanner:
    def __init__(self, result: ScanResult) -> None:
        self.result = result

    def scan(self, content: bytes) -> ScanResult:
        del content
        return self.result


class FailingStorage(LocalPrivateStorage):
    def put_object(self, key: str, content: bytes) -> None:
        del key, content
        raise DomainError("STORAGE_UPLOAD_FAILED", "Injected storage failure", 503)


def ready_claim(client: TestClient, db: Session, email: str) -> dict:
    contract_id = create_contract(client, db, email)
    claim = create_disease_claim(client, contract_id)
    response = client.post(
        f"/api/claims/{claim['claim_id']}/transitions",
        json={"action": "SUBMIT_ACCIDENT_INFORMATION"},
    )
    assert response.status_code == 200
    return response.json()


def upload_pdf(client: TestClient, claim_id: str, name: str = "diagnosis.pdf"):
    return client.post(
        f"/api/claims/{claim_id}/documents",
        data={"documentType": "DIAGNOSIS_CERTIFICATE"},
        files={"file": (name, b"%PDF-1.4\nclaimlens test\n%%EOF", "application/pdf")},
    )


def test_golden_private_upload_read_delete_and_audit(
    client: TestClient, db_session: Session, tmp_path: Path
) -> None:
    storage = LocalPrivateStorage(tmp_path / "private")
    client.app.dependency_overrides[get_object_storage] = lambda: storage
    client.app.dependency_overrides[get_malware_scanner] = lambda: FixedScanner(ScanResult.CLEAN)
    claim = ready_claim(client, db_session, "document-owner@example.com")
    uploaded = upload_pdf(client, claim["claim_id"])
    assert uploaded.status_code == 201
    document = uploaded.json()
    assert document["processing_status"] == "READY"
    assert document["malware_scan_status"] == "CLEAN"
    assert len(document["file_hash"]) == 64
    assert "storage_key" not in document
    document_id = document["document_id"]
    assert client.get(f"/api/claims/{claim['claim_id']}/documents").status_code == 200
    assert client.get(f"/api/documents/{document_id}").status_code == 200
    content = client.get(f"/api/documents/{document_id}/content?download=true")
    assert content.status_code == 200
    assert content.content.startswith(b"%PDF-")
    assert content.headers["x-content-type-options"] == "nosniff"
    assert content.headers["cache-control"] == "private, no-store"
    for event in (
        AuditEventType.DOCUMENT_UPLOAD,
        AuditEventType.DOCUMENT_VIEW,
        AuditEventType.DOCUMENT_DOWNLOAD,
    ):
        assert db_session.scalar(select(AuditLog).where(AuditLog.event_type == event)) is not None
    assert client.delete(f"/api/documents/{document_id}").status_code == 204
    row = db_session.get(MedicalDocument, UUID(document_id))
    assert row is not None and row.processing_status.value == "DELETED"
    assert not storage.exists(row.storage_key)


def test_document_idor_and_cancelled_claim_upload_are_blocked(
    client: TestClient, db_session: Session, tmp_path: Path
) -> None:
    storage = LocalPrivateStorage(tmp_path / "private")
    client.app.dependency_overrides[get_object_storage] = lambda: storage
    client.app.dependency_overrides[get_malware_scanner] = lambda: FixedScanner(ScanResult.CLEAN)
    claim = ready_claim(client, db_session, "document-a@example.com")
    document = upload_pdf(client, claim["claim_id"]).json()
    client.post("/api/auth/logout")
    ready_claim(client, db_session, "document-b@example.com")
    document_id = document["document_id"]
    assert client.get(f"/api/documents/{document_id}").status_code == 403
    assert client.get(f"/api/documents/{document_id}/content").status_code == 403
    assert (
        client.patch(f"/api/documents/{document_id}", json={"document_type": "OTHER"}).status_code
        == 403
    )
    assert client.delete(f"/api/documents/{document_id}").status_code == 403
    assert upload_pdf(client, claim["claim_id"]).status_code == 403

    client.post("/api/auth/logout")
    cancelled = ready_claim(client, db_session, "document-cancel@example.com")
    client.post(f"/api/claims/{cancelled['claim_id']}/cancel")
    assert upload_pdf(client, cancelled["claim_id"]).status_code == 409


def test_infected_scan_failure_duplicate_and_disguised_file_never_become_ready(
    client: TestClient, db_session: Session, tmp_path: Path
) -> None:
    storage = LocalPrivateStorage(tmp_path / "private")
    client.app.dependency_overrides[get_object_storage] = lambda: storage
    claim = ready_claim(client, db_session, "document-security@example.com")
    client.app.dependency_overrides[get_malware_scanner] = lambda: FixedScanner(ScanResult.INFECTED)
    assert upload_pdf(client, claim["claim_id"]).status_code == 422
    client.app.dependency_overrides[get_malware_scanner] = lambda: FixedScanner(
        ScanResult.SCAN_FAILED
    )
    assert upload_pdf(client, claim["claim_id"]).status_code == 503
    client.app.dependency_overrides[get_malware_scanner] = lambda: FixedScanner(ScanResult.CLEAN)
    disguised = client.post(
        f"/api/claims/{claim['claim_id']}/documents",
        data={"documentType": "OTHER"},
        files={"file": ("attack.pdf", b"MZ executable", "application/pdf")},
    )
    assert disguised.status_code == 422
    assert upload_pdf(client, claim["claim_id"]).status_code == 201
    assert upload_pdf(client, claim["claim_id"]).status_code == 409
    rows = list(db_session.scalars(select(MedicalDocument)))
    assert len(rows) == 1 and rows[0].processing_status.value == "READY"


def test_storage_failure_does_not_create_ready_metadata(
    client: TestClient, db_session: Session, tmp_path: Path
) -> None:
    client.app.dependency_overrides[get_object_storage] = lambda: FailingStorage(
        tmp_path / "private"
    )
    client.app.dependency_overrides[get_malware_scanner] = lambda: FixedScanner(ScanResult.CLEAN)
    claim = ready_claim(client, db_session, "document-storage-failure@example.com")
    assert upload_pdf(client, claim["claim_id"]).status_code == 503
    assert list(db_session.scalars(select(MedicalDocument))) == []
