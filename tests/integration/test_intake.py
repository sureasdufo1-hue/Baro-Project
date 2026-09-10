import json
from datetime import date
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
from domain.assessment.models import CoverageAssessment, EligibilityResult
from domain.calculation.models import BenefitCalculation
from domain.claim.models import Claim, ClaimStatus
from domain.contract.models import InsuranceContract, Insured
from domain.document.models import MedicalDocument
from domain.evidence.models import Evidence
from domain.fact.models import ExtractedFact, VerifiedFact
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
from tests.integration.test_contracts import master_fixture
from tests.integration.test_documents import FixedScanner
from tests.integration.test_insurance_master import login_as
from tests.integration.test_ocr_fact_flow import CapturingQueue
from tests.integration.test_reviews import credentials


def setup_payable_master(db: Session, user: User):
    version, coverage = master_fixture(db)
    policy = Policy(
        product_version_id=version.product_version_id,
        policy_name="Fast Intake Policy",
        policy_type=PolicyType.GENERAL,
    )
    db.add(policy)
    db.flush()

    policy_version = PolicyVersion(
        policy_id=policy.policy_id,
        version_code="V1",
        effective_from=date(2025, 1, 1),
        status=PolicyVersionStatus.ACTIVE,
    )
    db.add(policy_version)
    db.flush()

    eligibility_rule = BenefitRule(
        coverage_id=coverage.coverage_id,
        policy_version_id=policy_version.policy_version_id,
        rule_name="Acute MI Eligibility Rule",
        rule_type=RuleType.ELIGIBILITY,
        status=RuleStatus.ACTIVE,
    )
    db.add(eligibility_rule)
    db.flush()

    elig_version = RuleVersion(
        rule_id=eligibility_rule.rule_id,
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
    db.add(elig_version)

    calc_rule = BenefitRule(
        coverage_id=coverage.coverage_id,
        policy_version_id=policy_version.policy_version_id,
        rule_name="Fixed Acute MI Benefit Calculation",
        rule_type=RuleType.CALCULATION,
        status=RuleStatus.ACTIVE,
    )
    db.add(calc_rule)
    db.flush()

    calc_version = RuleVersion(
        rule_id=calc_rule.rule_id,
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
    db.add(calc_version)
    db.flush()

    clause = PolicyClause(
        policy_version_id=policy_version.policy_version_id,
        article_number="제1조",
        article_title="진단보험금",
        clause_text="급성심근경색증 진단 시 진단보험금을 지급합니다.",
        page_number=1,
        source_bbox={"x": 0.1, "y": 0.2, "width": 0.5, "height": 0.1},
        text_hash="test-clause-hash-intake",
    )
    db.add(clause)
    db.flush()

    db.add(BenefitRuleClause(rule_id=eligibility_rule.rule_id, clause_id=clause.clause_id))
    db.add(BenefitRuleClause(rule_id=calc_rule.rule_id, clause_id=clause.clause_id))
    db.commit()
    return version, coverage, policy_version


def test_fast_intake_multipart_with_files_and_full_pipeline(
    client: TestClient, db_session: Session, tmp_path: Path
) -> None:
    adjuster_creds = credentials("fast-intake-adjuster@example.com")
    login_as(client, db_session, adjuster_creds, UserRole.ADJUSTER)
    adjuster = db_session.scalar(select(User).where(User.email == adjuster_creds["email"]))
    assert adjuster is not None

    version, coverage, policy_version = setup_payable_master(db_session, adjuster)

    # Configure mocked infrastructure
    storage = LocalPrivateStorage(tmp_path / "fast-intake-storage")
    queue = CapturingQueue()
    client.app.dependency_overrides[get_object_storage] = lambda: storage
    client.app.dependency_overrides[get_malware_scanner] = lambda: FixedScanner(ScanResult.CLEAN)
    client.app.dependency_overrides[get_ocr_provider] = DevelopmentOCRProvider
    client.app.dependency_overrides[get_extraction_provider] = DevelopmentExtractionProvider
    client.app.dependency_overrides[get_ocr_queue] = lambda: queue

    pdf_content = (
        b"%PDF-1.4\n"
        b"FACT:DIAGNOSIS_CODE=I21.9|0.98\n"
        b"FACT:DIAGNOSIS_NAME=Acute myocardial infarction|0.96\n"
        b"FACT:DIAGNOSIS_DATE=2026-07-10|0.95\n"
        b"%%EOF"
    )

    intake_payload = {
        "insured": {
            "name": "홍길동",
            "birth_date": "1980-05-15",
            "gender": "MALE",
            "relationship_type": "SELF",
        },
        "contract": {
            "product_version_id": str(version.product_version_id),
            "policy_version_id": str(policy_version.policy_version_id),
            "policy_number": "POL-2026-09118",
            "contract_date": "2025-02-01",
            "coverage_start_date": "2025-02-01",
            "coverage_end_date": "2045-02-01",
            "coverages": [
                {
                    "coverage_id": str(coverage.coverage_id),
                    "coverage_name_snapshot": "급성심근경색증진단비",
                    "insured_amount": 50_000_000,
                }
            ],
        },
        "incident": {
            "claim_type": "DISEASE",
            "title": "급성심근경색증 진단비 원스톱 사정의뢰건",
            "diagnosis_date": "2026-07-10",
            "description": "급성심근경색증 진단 후 스텐트삽입술 시행",
        },
        "documents_metadata": [
            {
                "filename": "diagnosis_certificate.pdf",
                "document_type": "DIAGNOSIS_CERTIFICATE",
            }
        ],
        "options": {
            "auto_analyze": True,
            "auto_confirm_facts": True,
            "auto_assess": True,
            "create_review": True,
            "review_reason": "원스톱 사건 접수 손해사정 심사",
        },
    }

    res = client.post(
        "/api/intake",
        data={"payload": json.dumps(intake_payload)},
        files={"files": ("diagnosis_certificate.pdf", pdf_content, "application/pdf")},
    )

    assert res.status_code == 201, res.text
    data = res.json()
    claim_id = UUID(data["claim_id"])
    assert data["claim_number"].startswith("CLM-")
    assert data["documents_count"] == 1
    assert data["assessments_count"] == 1
    assert data["calculations_count"] == 1
    assert data["total_benefit_amount"] == 50_000_000
    assert data["review_id"] is not None
    assert data["review_status"] == "IN_PROGRESS"
    assert data["redirect_url"] == f"/reviews/{data['review_id']}"

    # Verify Database records
    claim = db_session.get(Claim, claim_id)
    assert claim is not None
    assert claim.status is ClaimStatus.MANUAL_REVIEW

    contract = db_session.get(InsuranceContract, UUID(data["contract_id"]))
    assert contract is not None
    assert contract.policy_number == "POL-2026-09118"

    insured = db_session.get(Insured, UUID(data["insured_id"]))
    assert insured is not None
    assert insured.name == "홍길동"

    docs = list(
        db_session.scalars(select(MedicalDocument).where(MedicalDocument.claim_id == claim_id))
    )
    assert len(docs) == 1
    assert docs[0].original_filename == "diagnosis_certificate.pdf"

    extracted_facts = list(
        db_session.scalars(select(ExtractedFact).where(ExtractedFact.claim_id == claim_id))
    )
    assert len(extracted_facts) >= 1

    verified_facts = list(
        db_session.scalars(select(VerifiedFact).where(VerifiedFact.claim_id == claim_id))
    )
    assert len(verified_facts) >= 1

    assessments = list(
        db_session.scalars(
            select(CoverageAssessment).where(CoverageAssessment.claim_id == claim_id)
        )
    )
    assert len(assessments) == 1
    assert assessments[0].eligibility_result == EligibilityResult.PAYABLE

    calcs = list(
        db_session.scalars(
            select(BenefitCalculation).where(BenefitCalculation.claim_id == claim_id)
        )
    )
    assert len(calcs) == 1
    assert calcs[0].final_amount == 50_000_000

    evidence = list(db_session.scalars(select(Evidence).where(Evidence.claim_id == claim_id)))
    assert len(evidence) > 0

    review = db_session.get(Review, UUID(data["review_id"]))
    assert review is not None
    assert review.reviewer_user_id == adjuster.user_id
    assert review.review_status == ReviewStatus.IN_PROGRESS


def test_fast_intake_json_direct_facts_without_files(
    client: TestClient, db_session: Session, tmp_path: Path
) -> None:
    adjuster_creds = credentials("fast-intake-adjuster-2@example.com")
    login_as(client, db_session, adjuster_creds, UserRole.ADJUSTER)
    adjuster = db_session.scalar(select(User).where(User.email == adjuster_creds["email"]))
    assert adjuster is not None

    storage = LocalPrivateStorage(tmp_path / "fast-intake-storage-2")
    client.app.dependency_overrides[get_object_storage] = lambda: storage
    client.app.dependency_overrides[get_malware_scanner] = lambda: FixedScanner(ScanResult.CLEAN)
    client.app.dependency_overrides[get_ocr_provider] = DevelopmentOCRProvider
    client.app.dependency_overrides[get_extraction_provider] = DevelopmentExtractionProvider

    version, coverage, policy_version = setup_payable_master(db_session, adjuster)

    intake_payload = {
        "insured": {
            "name": "이순신",
            "birth_date": "1975-04-28",
            "gender": "MALE",
            "relationship_type": "OTHER",
        },
        "contract": {
            "product_version_id": str(version.product_version_id),
            "policy_version_id": str(policy_version.policy_version_id),
            "policy_number": "POL-DIRECT-001",
            "contract_date": "2025-01-10",
            "coverage_start_date": "2025-01-10",
            "coverage_end_date": "2045-01-10",
            "coverages": [
                {
                    "coverage_id": str(coverage.coverage_id),
                    "coverage_name_snapshot": "급성심근경색증진단비",
                    "insured_amount": 30_000_000,
                }
            ],
        },
        "incident": {
            "claim_type": "DISEASE",
            "title": "급성심근경색증 직접 팩트 접수건",
            "diagnosis_date": "2026-07-10",
            "description": "응급실 진단 직접 입력",
        },
        "direct_facts": [
            {"fact_type": "DIAGNOSIS_CODE", "value": "I21.9"},
            {"fact_type": "DIAGNOSIS_NAME", "value": "Acute myocardial infarction"},
            {"fact_type": "DIAGNOSIS_DATE", "value": "2026-07-10"},
        ],
        "options": {
            "auto_analyze": True,
            "auto_confirm_facts": True,
            "auto_assess": True,
            "create_review": True,
            "review_reason": "직접 팩트 입력에 따른 손해사정 심사",
        },
    }

    res = client.post("/api/intake/json", json=intake_payload)
    assert res.status_code == 201, res.text
    data = res.json()

    assert data["documents_count"] == 1
    assert data["assessments_count"] == 1
    assert data["calculations_count"] == 1
    assert data["total_benefit_amount"] == 30_000_000
    assert data["review_id"] is not None
    assert data["review_status"] == "IN_PROGRESS"


def test_intake_forbidden_for_normal_user(client: TestClient, db_session: Session) -> None:
    user_creds = credentials("normal-claimant@example.com")
    login_as(client, db_session, user_creds, UserRole.USER)

    res = client.post("/api/intake/json", json={})
    assert res.status_code == 403
