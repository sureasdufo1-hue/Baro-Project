import uuid
from datetime import date
from decimal import Decimal
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
from domain.assessment.models import AssessmentStatus, CoverageAssessment, EligibilityResult
from domain.audit.models import AuditEventType, AuditLog
from domain.calculation.models import BenefitCalculation, CalculationStatus
from domain.claim.models import Claim, ClaimStatus
from domain.contract.models import ContractCoverage, InsuranceContract
from domain.fact.models import OCRResult
from domain.fact.service import process_ocr
from domain.policy.models import (
    Policy,
    PolicyClause,
    PolicyType,
    PolicyVersion,
    PolicyVersionStatus,
)
from domain.review.models import Review, ReviewStatus
from domain.rule.models import (
    BenefitRule,
    BenefitRuleClause,
    RuleSourceType,
    RuleStatus,
    RuleType,
    RuleVersion,
)
from domain.user.models import User, UserRole
from infrastructure.ai.provider import DevelopmentExtractionProvider
from infrastructure.ocr.provider import DevelopmentOCRProvider
from infrastructure.security.malware import ScanResult
from infrastructure.storage.object_storage import LocalPrivateStorage
from tests.integration.test_claims import create_contract, create_disease_claim
from tests.integration.test_contracts import master_fixture
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


def test_additional_document_submission_resumes_and_finalizes_review(
    client: TestClient, db_session: Session, tmp_path: Path
) -> None:
    owner_email = "finalize-owner@example.com"
    version, coverage = master_fixture(db_session)
    contract_id = create_contract(client, db_session, owner_email)
    payload = create_disease_claim(client, contract_id)
    claim = db_session.get(Claim, uuid.UUID(payload["claim_id"]))
    contract = db_session.get(InsuranceContract, uuid.UUID(contract_id))
    user = db_session.scalar(select(User).where(User.email == owner_email))
    assert claim is not None and contract is not None and user is not None

    subscribed = ContractCoverage(
        contract_id=contract.contract_id,
        coverage_id=coverage.coverage_id,
        coverage_name_snapshot="Acute MI benefit",
        insured_amount=30_000_000,
    )
    policy = Policy(
        product_version_id=version.product_version_id,
        policy_name="Review finalize policy",
        policy_type=PolicyType.GENERAL,
    )
    db_session.add_all([subscribed, policy])
    db_session.flush()

    policy_version = PolicyVersion(
        policy_id=policy.policy_id,
        version_code="V1",
        effective_from=date(2025, 1, 1),
        status=PolicyVersionStatus.ACTIVE,
    )
    db_session.add(policy_version)
    db_session.flush()

    rule = BenefitRule(
        coverage_id=coverage.coverage_id,
        policy_version_id=policy_version.policy_version_id,
        rule_name="Diagnosis code eligibility",
        rule_type=RuleType.ELIGIBILITY,
        status=RuleStatus.ACTIVE,
    )
    db_session.add(rule)
    db_session.flush()

    rule_version = RuleVersion(
        rule_id=rule.rule_id,
        version_no=1,
        status=RuleStatus.ACTIVE,
        source_type=RuleSourceType.MANUAL,
        created_by=user.user_id,
        rule_definition={
            "schemaVersion": "1.0",
            "ruleType": "ELIGIBILITY",
            "conditions": [{"path": "facts.DIAGNOSIS_CODE", "operator": "IN", "value": ["I21.9"]}],
        },
    )
    calculation_rule = BenefitRule(
        coverage_id=coverage.coverage_id,
        policy_version_id=policy_version.policy_version_id,
        rule_name="Fixed diagnosis benefit calculation",
        rule_type=RuleType.CALCULATION,
        status=RuleStatus.ACTIVE,
    )
    db_session.add(calculation_rule)
    db_session.flush()

    calc_rule_version = RuleVersion(
        rule_id=calculation_rule.rule_id,
        version_no=1,
        status=RuleStatus.ACTIVE,
        source_type=RuleSourceType.MANUAL,
        created_by=user.user_id,
        rule_definition={
            "schemaVersion": 1,
            "ruleType": "CALCULATION",
            "strategy": "FIXED_BENEFIT",
            "parameters": {
                "paymentRate": "1.0",
                "deductionAmount": 0,
                "roundingMode": "DOWN",
                "roundingUnit": 1,
            },
        },
    )
    clause = PolicyClause(
        policy_version_id=policy_version.policy_version_id,
        article_number="제1조",
        article_title="진단보험금",
        paragraph_number=None,
        item_number=None,
        clause_text="테스트용 진단보험금 지급 조항",
        page_number=7,
        source_bbox={"x": 0.1, "y": 0.2, "width": 0.5, "height": 0.1},
        text_hash="test-clause-hash",
    )
    db_session.add_all([rule_version, calc_rule_version, clause])
    db_session.flush()

    db_session.add(BenefitRuleClause(rule_id=rule.rule_id, clause_id=clause.clause_id))
    db_session.add(BenefitRuleClause(rule_id=calculation_rule.rule_id, clause_id=clause.clause_id))
    db_session.flush()

    initial_assessment = CoverageAssessment(
        claim_id=claim.claim_id,
        contract_coverage_id=subscribed.contract_coverage_id,
        policy_version_id=policy_version.policy_version_id,
        rule_version_id=rule_version.rule_version_id,
        calculation_rule_version_id=calc_rule_version.rule_version_id,
        assessment_status=AssessmentStatus.COMPLETED,
        match_score=Decimal("1.0"),
        eligibility_result=EligibilityResult.MANUAL_REVIEW,
        exclusion_result="NONE",
        reduction_result="NONE",
        reason_summary="Initial assessment requires additional document review",
        resolution_snapshot={"note": "initial manual review"},
    )
    db_session.add(initial_assessment)
    claim.status = ClaimStatus.MANUAL_REVIEW
    db_session.commit()

    # Admin creates review with assessment_id
    client.post("/api/auth/logout")
    admin_data = credentials("finalize-admin@example.com")
    login_as(client, db_session, admin_data, UserRole.SYSTEM_ADMIN)
    created = client.post(
        "/api/reviews",
        json={
            "claim_id": str(claim.claim_id),
            "assessment_id": str(initial_assessment.assessment_id),
            "review_type": "GENERAL_CLAIM_REVIEW",
            "reason": "TEST additional evidence needed for finalization",
        },
    )
    assert created.status_code == 201
    review_id = created.json()["review_id"]

    # Assign adjuster
    adjuster_data = credentials("finalize-adjuster@example.com")
    login_as(client, db_session, adjuster_data, UserRole.ADJUSTER)
    adjuster = db_session.scalar(select(User).where(User.email == adjuster_data["email"]))
    assert adjuster is not None
    client.post("/api/auth/logout")
    client.post(
        "/api/auth/login",
        json={"email": admin_data["email"], "password": admin_data["password"]},
    )
    client.post(
        f"/api/reviews/{review_id}/assign",
        json={"reviewer_user_id": str(adjuster.user_id)},
    )

    # Adjuster accepts and requests document
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
            "reason": "Need confirmed diagnosis code",
            "user_message": "Please upload diagnosis certificate",
        },
    )
    assert requested.status_code == 200
    request_id = requested.json()["request_id"]

    # Owner uploads document, OCR runs, facts confirmed, resume review
    storage = LocalPrivateStorage(tmp_path / "finalize-private")
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
        files={"file": ("test-finalize.pdf", content, "application/pdf")},
    )
    assert upload.status_code == 201
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

    # Adjuster finalizes review
    client.post("/api/auth/logout")
    client.post(
        "/api/auth/login",
        json={"email": adjuster_data["email"], "password": adjuster_data["password"]},
    )
    finalized = client.post(
        f"/api/reviews/{review_id}/finalize",
        json={
            "final_eligibility": "PAYABLE",
            "opinion": "Additional diagnosis certificate verified as I21.9",
        },
    )
    assert finalized.status_code == 200, finalized.json()
    assert finalized.json()["review_status"] == ReviewStatus.COMPLETED
    assert finalized.json()["final_result"]["eligibility_result"] == "PAYABLE"
    assert finalized.json()["final_result"]["additional_documents_processed"] is True

    new_assessment_id = UUID(finalized.json()["final_result"]["assessment_id"])
    assert new_assessment_id != initial_assessment.assessment_id

    calculation_id = UUID(finalized.json()["final_result"]["calculation_id"])
    calculation = db_session.get(BenefitCalculation, calculation_id)
    assert calculation is not None
    assert calculation.calculation_status is CalculationStatus.CALCULATED
    assert calculation.final_amount == 30_000_000

    db_session.refresh(claim)
    assert claim.status is ClaimStatus.COMPLETED

    finalize_audit = db_session.scalar(
        select(AuditLog).where(AuditLog.event_type == AuditEventType.REVIEW_FINALIZE)
    )
    assert finalize_audit is not None
