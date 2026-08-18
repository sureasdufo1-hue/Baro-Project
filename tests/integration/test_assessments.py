import uuid
from datetime import UTC, date, datetime
from decimal import Decimal

from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session

from domain.calculation.models import BenefitCalculation, CalculationStatus
from domain.claim.models import Claim, ClaimStatus
from domain.contract.models import ContractCoverage, InsuranceContract
from domain.document.models import (
    DocumentProcessingStatus,
    DocumentType,
    DocumentTypeSource,
    MalwareScanStatus,
    MedicalDocument,
)
from domain.fact.models import (
    ExtractedFact,
    FactType,
    OCRResult,
    OCRStatus,
    VerificationStatus,
    VerifiedFact,
)
from domain.policy.models import (
    Policy,
    PolicyClause,
    PolicyType,
    PolicyVersion,
    PolicyVersionStatus,
)
from domain.review.models import ReviewStatus
from domain.rule.models import (
    BenefitRule,
    BenefitRuleClause,
    RuleSourceType,
    RuleStatus,
    RuleType,
    RuleVersion,
)
from domain.user.models import User, UserRole
from tests.integration.test_claims import create_contract, create_disease_claim
from tests.integration.test_contracts import master_fixture
from tests.integration.test_insurance_master import login_as
from tests.integration.test_reviews import credentials


def test_golden_deterministic_assessment_and_object_authorization(
    client: TestClient, db_session: Session
) -> None:
    version, coverage = master_fixture(db_session)
    contract_id = create_contract(client, db_session, "assessment-owner@example.com")
    claim_payload = create_disease_claim(client, contract_id)
    claim = db_session.get(Claim, uuid.UUID(claim_payload["claim_id"]))
    contract = db_session.get(InsuranceContract, uuid.UUID(contract_id))
    user = db_session.scalar(select(User).where(User.email == "assessment-owner@example.com"))
    assert claim is not None and contract is not None and user is not None
    claim.status = ClaimStatus.USER_VERIFICATION
    subscribed = ContractCoverage(
        contract_id=contract.contract_id,
        coverage_id=coverage.coverage_id,
        coverage_name_snapshot="Acute MI benefit",
        insured_amount=30_000_000,
    )
    policy = Policy(
        product_version_id=version.product_version_id,
        policy_name="Assessment policy",
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
    calculation_rule_version = RuleVersion(
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
    document = MedicalDocument(
        claim_id=claim.claim_id,
        user_id=user.user_id,
        document_type=DocumentType.DIAGNOSIS_CERTIFICATE,
        document_type_source=DocumentTypeSource.USER,
        original_filename="diagnosis.pdf",
        storage_key=f"tests/{claim.claim_id}/diagnosis.pdf",
        file_hash="a" * 64,
        mime_type="application/pdf",
        file_size=1024,
        page_count=1,
        malware_scan_status=MalwareScanStatus.CLEAN,
        processing_status=DocumentProcessingStatus.COMPLETED,
    )
    db_session.add_all([clause, document])
    db_session.flush()
    db_session.add_all(
        [
            BenefitRuleClause(rule_id=rule.rule_id, clause_id=clause.clause_id),
            BenefitRuleClause(rule_id=calculation_rule.rule_id, clause_id=clause.clause_id),
        ]
    )
    ocr = OCRResult(
        document_id=document.document_id,
        provider="TEST",
        model_name="fixture",
        model_version="1",
        raw_text=None,
        raw_result=None,
        confidence=Decimal("0.99"),
        status=OCRStatus.SUCCEEDED,
    )
    db_session.add(ocr)
    db_session.flush()
    extracted = ExtractedFact(
        claim_id=claim.claim_id,
        document_id=document.document_id,
        ocr_result_id=ocr.ocr_result_id,
        fact_type=FactType.DIAGNOSIS_CODE,
        fact_value="I21.9",
        normalized_value="I21.9",
        confidence=Decimal("0.99"),
        page_number=1,
        source_bbox={"x": 0.2, "y": 0.3, "width": 0.2, "height": 0.05},
        source_text="I21.9",
        extractor_provider="TEST",
        extractor_model="fixture",
        prompt_version="1",
    )
    db_session.add(extracted)
    db_session.flush()
    fact = VerifiedFact(
        claim_id=claim.claim_id,
        extracted_fact_id=extracted.extracted_fact_id,
        fact_type=FactType.DIAGNOSIS_CODE,
        verified_value="I21.9",
        verification_status=VerificationStatus.USER_CONFIRMED,
        verified_by=user.user_id,
        verified_at=datetime.now(UTC),
        source_document_id=document.document_id,
        source_page=1,
        source_bbox=extracted.source_bbox,
    )
    db_session.add_all([rule_version, calculation_rule_version, fact])
    db_session.commit()
    response = client.post(f"/api/claims/{claim.claim_id}/assess")
    assert response.status_code == 201
    assert response.json()[0]["eligibility_result"] == "PAYABLE"
    assessment_id = response.json()[0]["assessment_id"]

    first = client.post(f"/api/assessments/{assessment_id}/calculate")
    assert first.status_code == 201
    first_payload = first.json()
    assert first_payload["calculation_version"] == 1
    assert first_payload["insured_amount_snapshot"] == 30_000_000
    assert first_payload["final_amount"] == 30_000_000
    evidence = client.post(f"/api/calculations/{first_payload['calculation_id']}/evidence")
    assert evidence.status_code == 201
    db_session.refresh(claim)
    assert claim.status is ClaimStatus.COMPLETED
    evidence_types = {item["evidence_type"] for item in evidence.json()}
    assert {"POLICY_CLAUSE", "VERIFIED_FACT", "DOCUMENT", "CALCULATION"} <= evidence_types
    repeated_evidence = client.post(f"/api/calculations/{first_payload['calculation_id']}/evidence")
    assert repeated_evidence.status_code == 201
    assert {item["evidence_id"] for item in repeated_evidence.json()} == {
        item["evidence_id"] for item in evidence.json()
    }
    result = client.get(f"/api/claims/{claim.claim_id}/result")
    assert result.status_code == 200
    assert result.json()["total_expected_amount"] == 30_000_000
    assert result.json()["items"][0]["evidence_complete"] is True
    trace = client.get(f"/api/calculations/{first_payload['calculation_id']}/trace")
    assert trace.status_code == 200
    assert trace.json()[-1]["step_type"] == "CALCULATION"

    repeated = client.post(f"/api/assessments/{assessment_id}/calculate")
    assert repeated.status_code == 201
    assert repeated.json()["calculation_id"] == first_payload["calculation_id"]

    subscribed.insured_amount = 15_000_000
    db_session.commit()
    second = client.post(f"/api/assessments/{assessment_id}/recalculate")
    assert second.status_code == 201
    second_payload = second.json()
    assert second_payload["calculation_version"] == 2
    assert second_payload["previous_calculation_id"] == first_payload["calculation_id"]
    assert second_payload["insured_amount_snapshot"] == 15_000_000
    assert second_payload["final_amount"] == 15_000_000
    second_evidence = client.post(f"/api/calculations/{second_payload['calculation_id']}/evidence")
    assert second_evidence.status_code == 201
    assert {item["evidence_id"] for item in evidence.json()}.isdisjoint(
        {item["evidence_id"] for item in second_evidence.json()}
    )

    original = db_session.get(BenefitCalculation, uuid.UUID(first_payload["calculation_id"]))
    assert original is not None
    assert original.insured_amount_snapshot == 30_000_000
    assert original.calculation_status == CalculationStatus.SUPERSEDED
    history = client.get(f"/api/assessments/{assessment_id}/calculations")
    assert history.status_code == 200
    assert [item["calculation_version"] for item in history.json()] == [2, 1]

    claim.status = ClaimStatus.MANUAL_REVIEW
    claim.completed_at = None
    db_session.commit()
    client.post("/api/auth/logout")
    admin_data = credentials("assessment-review-admin@example.com")
    login_as(client, db_session, admin_data, UserRole.SYSTEM_ADMIN)
    created_review = client.post(
        "/api/reviews",
        json={
            "claim_id": str(claim.claim_id),
            "assessment_id": assessment_id,
            "review_type": "FACT_REVIEW",
            "reason": "TEST expert correction",
        },
    )
    assert created_review.status_code == 201
    review_id = created_review.json()["review_id"]
    client.post("/api/auth/logout")
    adjuster_data = credentials("assessment-adjuster@example.com")
    login_as(client, db_session, adjuster_data, UserRole.ADJUSTER)
    adjuster = db_session.scalar(select(User).where(User.email == adjuster_data["email"]))
    assert adjuster is not None
    client.post("/api/auth/logout")
    client.post(
        "/api/auth/login",
        json={"email": admin_data["email"], "password": admin_data["password"]},
    )
    assert (
        client.post(
            f"/api/reviews/{review_id}/assign",
            json={"reviewer_user_id": str(adjuster.user_id)},
        ).status_code
        == 200
    )
    client.post("/api/auth/logout")
    client.post(
        "/api/auth/login",
        json={"email": adjuster_data["email"], "password": adjuster_data["password"]},
    )
    assert client.post(f"/api/reviews/{review_id}/accept").status_code == 200
    modified_review = client.post(
        f"/api/reviews/{review_id}/modify",
        json={
            "fact_id": str(fact.verified_fact_id),
            "new_value": "I21.9",
            "reason": "TEST expert source verification",
            "final_eligibility": "PAYABLE",
            "opinion": "TEST correction completed",
        },
    )
    assert modified_review.status_code == 200
    assert modified_review.json()["review_status"] == ReviewStatus.COMPLETED
    assert modified_review.json()["final_result"]["evidence_version"] == 3
    duplicate_modify = client.post(
        f"/api/reviews/{review_id}/modify",
        json={
            "fact_id": str(fact.verified_fact_id),
            "new_value": "I21.9",
            "reason": "TEST duplicate submission",
            "final_eligibility": "PAYABLE",
        },
    )
    assert duplicate_modify.status_code == 409
    expert_calculation = db_session.get(
        BenefitCalculation,
        uuid.UUID(modified_review.json()["final_result"]["calculation_id"]),
    )
    assert expert_calculation is not None and expert_calculation.calculation_version == 3
    db_session.refresh(claim)
    assert claim.status is ClaimStatus.COMPLETED

    client.post("/api/auth/logout")
    create_contract(client, db_session, "assessment-other@example.com")
    assert client.get(f"/api/assessments/{assessment_id}").status_code == 403
    assert client.get(f"/api/calculations/{second_payload['calculation_id']}").status_code == 403
    assert (
        client.get(f"/api/calculations/{second_payload['calculation_id']}/evidence").status_code
        == 403
    )
    assert client.get(f"/api/claims/{claim.claim_id}/result").status_code == 403
