from __future__ import annotations

from datetime import date, datetime
from decimal import Decimal
from uuid import uuid4

import pytest
from sqlalchemy.orm import Session

from domain.assessment.models import AssessmentStatus, CoverageAssessment, EligibilityResult
from domain.calculation.models import BenefitCalculation, CalculationStatus
from domain.claim.models import Accident, Claim, ClaimStatus, ClaimType
from domain.contract.models import (
    ContractCoverage,
    CoverageStatus,
    Gender,
    InsuranceContract,
    Insured,
    RelationshipType,
)
from domain.fact.models import FactType, VerificationStatus, VerifiedFact
from domain.policy.models import (
    InsuranceCompany,
    InsuranceProduct,
    InsuranceType,
    Policy,
    PolicyClause,
    PolicyType,
    PolicyVersion,
    PolicyVersionStatus,
    ProductVersion,
    VersionStatus,
)
from domain.review.models import Review, ReviewStatus, ReviewType
from domain.review.report import build_loss_assessment_report
from domain.user.models import User, UserRole, UserStatus
from shared.errors import DomainError
from shared.utils.currency import format_korean_currency


def test_format_korean_currency() -> None:
    assert format_korean_currency(0) == "금 영원정"
    assert format_korean_currency(30000) == "금 삼만원정"
    assert format_korean_currency(150000) == "금 십오만원정"
    assert format_korean_currency(2500000) == "금 이백오십만원정"
    assert format_korean_currency(50000000) == "금 오천만원정"
    assert format_korean_currency(125000000) == "금 일억이천오백만원정"
    assert format_korean_currency(-50000) == "-금 오만원정"


def test_build_loss_assessment_report(db_session: Session) -> None:
    user = User(
        email="adjuster_test@baro.local",
        password_hash="hashed_pw",
        display_name="김사정",
        role=UserRole.ADJUSTER,
        status=UserStatus.ACTIVE,
    )
    db_session.add(user)
    db_session.flush()

    insured = Insured(
        owner_user_id=user.user_id,
        name="홍길동",
        birth_date=date(1985, 5, 12),
        gender=Gender.MALE,
        relationship_type=RelationshipType.SELF,
    )
    db_session.add(insured)
    db_session.flush()

    company = InsuranceCompany(
        company_code="DB_TEST",
        company_name="DB손해보험",
        company_type="NON_LIFE",
    )
    db_session.add(company)
    db_session.flush()

    product = InsuranceProduct(
        company_id=company.company_id,
        product_code="31100",
        product_name="프로미라이프 건강보험",
        insurance_type=InsuranceType.THIRD_PARTY,
    )
    db_session.add(product)
    db_session.flush()

    prod_ver = ProductVersion(
        product_id=product.product_id,
        version_name="2026.01",
        status=VersionStatus.ACTIVE,
    )
    db_session.add(prod_ver)
    db_session.flush()

    policy = Policy(
        product_version_id=prod_ver.product_version_id,
        policy_name="일반암진단보장특약",
        policy_type=PolicyType.SPECIAL,
    )
    db_session.add(policy)
    db_session.flush()

    pol_ver = PolicyVersion(
        policy_id=policy.policy_id,
        version_code="V1.0",
        effective_from=date(2026, 1, 1),
        status=PolicyVersionStatus.ACTIVE,
    )
    db_session.add(pol_ver)
    db_session.flush()

    clause = PolicyClause(
        policy_version_id=pol_ver.policy_version_id,
        article_number="특약 제3조",
        article_title="보험금의 지급사유",
        clause_text=(
            "피보험자가 보장개시일 이후에 일반암으로 진단확정된 경우 1회에 한하여 지급합니다."
        ),
    )
    db_session.add(clause)
    db_session.flush()

    contract = InsuranceContract(
        user_id=user.user_id,
        insured_id=insured.insured_id,
        product_version_id=prod_ver.product_version_id,
        policy_version_id=pol_ver.policy_version_id,
        policy_number="POL-2026-9999",
        contract_date=date(2026, 1, 15),
        coverage_start_date=date(2026, 1, 15),
        coverage_end_date=date(2046, 1, 14),
    )
    db_session.add(contract)
    db_session.flush()

    contract_coverage = ContractCoverage(
        contract_id=contract.contract_id,
        coverage_id=uuid4(),
        coverage_name_snapshot="일반암 진단비",
        insured_amount=50000000,
        status=CoverageStatus.ACTIVE,
    )
    db_session.add(contract_coverage)
    db_session.flush()

    claim = Claim(
        user_id=user.user_id,
        insured_id=insured.insured_id,
        contract_id=contract.contract_id,
        claim_number="CLM-20260911-TEST01",
        claim_type=ClaimType.DISEASE,
        status=ClaimStatus.COMPLETED,
        title="위암 진단비 청구 건",
    )
    claim.accident = Accident(
        accident_type=ClaimType.DISEASE,
        accident_date=date(2026, 8, 10),
        diagnosis_date=date(2026, 8, 10),
        description="상복부 불편감으로 내원하여 조직검사 결과 위암 확정진단",
        location="서울대학교병원",
    )
    db_session.add(claim)
    db_session.flush()

    fact_code = VerifiedFact(
        claim_id=claim.claim_id,
        extracted_fact_id=uuid4(),
        fact_type=FactType.DIAGNOSIS_CODE,
        verified_value="C16",
        verification_status=VerificationStatus.USER_CONFIRMED,
        verified_by=user.user_id,
        verified_at=datetime.now(),
        source_document_id=uuid4(),
    )
    fact_name = VerifiedFact(
        claim_id=claim.claim_id,
        extracted_fact_id=uuid4(),
        fact_type=FactType.DIAGNOSIS_NAME,
        verified_value="위의 악성 신생물 (위암)",
        verification_status=VerificationStatus.USER_CONFIRMED,
        verified_by=user.user_id,
        verified_at=datetime.now(),
        source_document_id=uuid4(),
    )
    db_session.add_all([fact_code, fact_name])
    db_session.flush()

    assessment = CoverageAssessment(
        claim_id=claim.claim_id,
        contract_coverage_id=contract_coverage.contract_coverage_id,
        policy_version_id=pol_ver.policy_version_id,
        assessment_status=AssessmentStatus.COMPLETED,
        match_score=Decimal("1.0"),
        eligibility_result=EligibilityResult.PAYABLE,
        reason_summary="C16 확정진단 및 면책기간 90일 경과 확인 완료",
        resolution_snapshot={},
    )
    db_session.add(assessment)
    db_session.flush()

    calc = BenefitCalculation(
        claim_id=claim.claim_id,
        assessment_id=assessment.assessment_id,
        contract_coverage_id=contract_coverage.contract_coverage_id,
        calculation_version=1,
        calculation_fingerprint="fingerprint_test_1",
        insured_amount_snapshot=50000000,
        payment_rate_snapshot=Decimal("1.0"),
        calculation_formula="insured_amount * payment_rate",
        calculation_input={"insured_amount": 50000000, "payment_rate": "1.0"},
        gross_amount=50000000,
        deduction_amount=0,
        final_amount=50000000,
        calculation_status=CalculationStatus.CALCULATED,
    )
    db_session.add(calc)
    db_session.flush()

    review = Review(
        claim_id=claim.claim_id,
        assessment_id=assessment.assessment_id,
        reviewer_user_id=user.user_id,
        review_type=ReviewType.GENERAL_CLAIM_REVIEW,
        review_status=ReviewStatus.COMPLETED,
        reason="일반암 진단비 지급 적정성 심사",
        opinion=(
            "병리조직검사 결과지 상 C16 침윤성 선암종 확정 확인. "
            "가입 후 면책기간 90일 경과하여 정상 지급이 타당함."
        ),
        previous_result={"eligible": True},
        final_result={"eligible": True, "final_amount": 50000000},
    )
    db_session.add(review)
    db_session.commit()

    report = build_loss_assessment_report(db_session, claim.claim_id, review.review_id)

    assert report["report_number"] == "RPT-CLM-20260911-TEST01"
    assert report["insured"]["name"] == "홍길동"
    assert report["insured"]["identity_masked"] == "198505-1******"
    assert report["contract"]["company_name"] == "DB손해보험"
    assert report["contract"]["product_name"] == "프로미라이프 건강보험"
    assert report["contract"]["policy_number"] == "POL-2026-9999"
    assert report["incident"]["claim_type"] == "DISEASE"
    assert len(report["medical_facts"]) == 2
    assert report["coverages"][0]["coverage_name"] == "일반암 진단비"
    assert report["coverages"][0]["article_number"] == "특약 제3조"
    assert report["coverages"][0]["final_amount"] == 50000000
    assert report["coverages"][0]["payment_rate"] == "100%"
    assert report["total_assessed_amount"] == 50000000
    assert report["total_assessed_amount_korean"] == "금 오천만원정"
    assert report["review"]["review_status"] == "COMPLETED"
    assert "면책기간 90일 경과" in report["review"]["opinion"]
    assert report["adjuster"]["name"] == "김사정"


def test_build_report_nonexistent_claim(db_session: Session) -> None:
    with pytest.raises(DomainError) as exc_info:
        build_loss_assessment_report(db_session, uuid4())
    assert exc_info.value.code == "CLAIM_NOT_FOUND"


def test_review_update_opinion(db_session: Session) -> None:
    user = User(
        email="adjuster_op@baro.local",
        password_hash="hashed_pw",
        display_name="이손해",
        role=UserRole.ADJUSTER,
        status=UserStatus.ACTIVE,
    )
    db_session.add(user)
    db_session.flush()

    review = Review(
        claim_id=uuid4(),
        reviewer_user_id=user.user_id,
        review_type=ReviewType.GENERAL_CLAIM_REVIEW,
        review_status=ReviewStatus.IN_PROGRESS,
        reason="심사 진행 중",
        opinion="초기 의견",
    )
    db_session.add(review)
    db_session.commit()

    review.opinion = "수정된 최종 의견: 정상 지급 결론."
    db_session.commit()

    updated = db_session.get(Review, review.review_id)
    assert updated is not None
    assert updated.opinion == "수정된 최종 의견: 정상 지급 결론."

