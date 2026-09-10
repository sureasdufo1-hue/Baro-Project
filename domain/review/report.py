from __future__ import annotations

from typing import Any
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.orm import Session

from domain.assessment.models import CoverageAssessment
from domain.calculation.models import BenefitCalculation
from domain.claim.models import Claim
from domain.contract.models import ContractCoverage, InsuranceContract, Insured
from domain.document.models import MedicalDocument
from domain.evidence.models import Evidence, EvidenceType
from domain.fact.models import VerifiedFact
from domain.policy.models import InsuranceCompany, InsuranceProduct, PolicyClause, ProductVersion
from domain.review.models import Review
from domain.user.models import User
from shared.errors import DomainError
from shared.utils.currency import format_korean_currency

FACT_LABELS: dict[str, str] = {
    "DIAGNOSIS_CODE": "진단코드 (KCD)",
    "DIAGNOSIS_NAME": "진단명",
    "DIAGNOSIS_DATE": "진단확정일",
    "SURGERY_NAME": "수술명",
    "SURGERY_DATE": "수술일자",
    "ADMISSION_DATE": "입원일자",
    "DISCHARGE_DATE": "퇴원일자",
    "HOSPITAL_ADMISSION_DATE": "입원일자",
    "HOSPITAL_DISCHARGE_DATE": "퇴원일자",
    "MEDICAL_FACILITY": "의료기관",
    "HOSPITAL_NAME": "의료기관",
    "DOCTOR_NAME": "담당의사",
    "DOCUMENT_ISSUE_DATE": "서류발급일자",
    "ACCIDENT_DATE": "사고일자",
    "DISABILITY_RATE": "후유장해지급률",
    "DISABILITY_DATE": "장해진단일자",
    "ACTUAL_LOSS_AMOUNT": "실손해액",
    "COPAYMENT_AMOUNT": "본인부담금",
    "NON_BENEFIT_AMOUNT": "비급여금액",
    "TREATMENT_COST": "총치료비용",
}

DOCUMENT_TYPE_LABELS: dict[str, str] = {
    "DIAGNOSIS_CERTIFICATE": "진단서",
    "SURGERY_CERTIFICATE": "수술확인서",
    "HOSPITALIZATION_CERTIFICATE": "입퇴원확인서",
    "MEDICAL_RECEIPT": "진료비영수증",
    "MEDICAL_DETAIL": "진료비세부내역서",
    "INSURANCE_POLICY": "보험증권",
    "ACCIDENT_REPORT": "사고보고서",
    "OTHER": "기타 의무기록",
}


def build_loss_assessment_report(
    db: Session,
    claim_id: UUID,
    review_id: UUID | None = None,
    adjuster_override: dict[str, str] | None = None,
) -> dict[str, Any]:
    """Assembles all data necessary to generate a formal Korean Loss Assessment Report

    (손해사정보고서).
    """
    claim = db.scalar(select(Claim).where(Claim.claim_id == claim_id))
    if claim is None:
        raise DomainError("CLAIM_NOT_FOUND", "Claim was not found", 404)

    insured = db.scalar(select(Insured).where(Insured.insured_id == claim.insured_id))
    contract = db.scalar(
        select(InsuranceContract).where(InsuranceContract.contract_id == claim.contract_id)
    )

    company_name = "보험회사"
    product_name = "보험상품"
    product_code = "미지정"

    if contract:
        product_version = db.scalar(
            select(ProductVersion).where(
                ProductVersion.product_version_id == contract.product_version_id
            )
        )
        if product_version:
            product = db.scalar(
                select(InsuranceProduct).where(
                    InsuranceProduct.product_id == product_version.product_id
                )
            )
            if product:
                product_name = product.product_name
                product_code = product.product_code
                company = db.scalar(
                    select(InsuranceCompany).where(
                        InsuranceCompany.company_id == product.company_id
                    )
                )
                if company:
                    company_name = company.company_name

    accident = claim.accident

    # 1. Parties Info
    birth_str = insured.birth_date.isoformat() if insured and insured.birth_date else "-"
    masked_id = f"{birth_str.replace('-', '')[:6]}-1******" if insured else "-"
    insured_info = {
        "name": insured.name if insured else "-",
        "birth_date": birth_str,
        "gender": insured.gender.value if insured else "-",
        "relationship_type": insured.relationship_type.value if insured else "-",
        "identity_masked": masked_id,
    }

    contract_period = None
    if contract and contract.coverage_start_date:
        if contract.coverage_end_date:
            contract_period = (
                f"{contract.coverage_start_date.isoformat()} ~ "
                f"{contract.coverage_end_date.isoformat()}"
            )
        else:
            contract_period = f"{contract.coverage_start_date.isoformat()} ~ 종신"

    contract_info = {
        "company_name": company_name,
        "product_name": product_name,
        "product_code": product_code,
        "policy_number": (contract.policy_number if contract else None) or claim.claim_number,
        "contract_date": (
            contract.contract_date.isoformat() if contract and contract.contract_date else None
        ),
        "coverage_period": contract_period,
        "contract_status": contract.contract_status.value if contract else "-",
    }

    # 2. Incident & Medical Facts
    incident_info = {
        "claim_type": claim.claim_type.value,
        "accident_date": (
            accident.accident_date.isoformat() if accident and accident.accident_date else None
        ),
        "diagnosis_date": (
            accident.diagnosis_date.isoformat() if accident and accident.diagnosis_date else None
        ),
        "onset_date": accident.onset_date.isoformat() if accident and accident.onset_date else None,
        "location": accident.location if accident else None,
        "description": accident.description if accident else None,
    }

    verified_facts_raw = list(
        db.scalars(
            select(VerifiedFact)
            .where(VerifiedFact.claim_id == claim_id)
            .order_by(VerifiedFact.created_at)
        )
    )
    facts_list = []
    for vf in verified_facts_raw:
        ft_val = vf.fact_type.value if hasattr(vf.fact_type, "value") else str(vf.fact_type)
        facts_list.append(
            {
                "fact_id": str(vf.verified_fact_id),
                "fact_type": ft_val,
                "label": FACT_LABELS.get(ft_val, ft_val),
                "fact_value": str(vf.verified_value),
            }
        )

    # 3. Coverages & Calculations
    assessments = list(
        db.scalars(
            select(CoverageAssessment)
            .where(CoverageAssessment.claim_id == claim_id)
            .order_by(CoverageAssessment.created_at)
        )
    )

    coverages_list = []
    total_assessed_amount = 0

    for ass in assessments:
        coverage = db.scalar(
            select(ContractCoverage).where(
                ContractCoverage.contract_coverage_id == ass.contract_coverage_id
            )
        )
        calc = db.scalar(
            select(BenefitCalculation).where(
                BenefitCalculation.assessment_id == ass.assessment_id,
                BenefitCalculation.is_current.is_(True),
            )
        )

        article_number = None
        article_title = None
        clause_text = None

        if calc:
            clause_ev = db.scalar(
                select(Evidence).where(
                    Evidence.calculation_id == calc.calculation_id,
                    Evidence.evidence_type == EvidenceType.POLICY_CLAUSE,
                )
            )
            if clause_ev and clause_ev.policy_clause_id:
                clause = db.scalar(
                    select(PolicyClause).where(PolicyClause.clause_id == clause_ev.policy_clause_id)
                )
                if clause:
                    article_number = clause.article_number
                    article_title = clause.article_title
                    clause_text = clause.clause_text

        if not article_number and ass.policy_version_id:
            clause = db.scalar(
                select(PolicyClause).where(PolicyClause.policy_version_id == ass.policy_version_id)
            )
            if clause:
                article_number = clause.article_number
                article_title = clause.article_title
                clause_text = clause.clause_text

        final_amount = calc.final_amount if calc else 0
        calc_status = calc.calculation_status.value if calc else "NOT_CALCULATED"
        formula = calc.calculation_formula if calc else None

        payment_rate_str = "-"
        if calc and calc.payment_rate_snapshot is not None:
            pct = float(calc.payment_rate_snapshot) * 100
            payment_rate_str = f"{pct:.0f}%" if pct.is_integer() else f"{pct:.1f}%"
        elif calc and calc.calculation_input:
            inp = calc.calculation_input
            rate_val = inp.get("payment_rate") or inp.get("paymentRate")
            if rate_val is not None:
                try:
                    pct = float(rate_val) * 100
                    payment_rate_str = f"{pct:.0f}%" if pct.is_integer() else f"{pct:.1f}%"
                except (ValueError, TypeError):
                    payment_rate_str = str(rate_val)

        if ass.eligibility_result.value == "PAYABLE" and final_amount > 0:
            total_assessed_amount += final_amount

        coverages_list.append(
            {
                "contract_coverage_id": str(ass.contract_coverage_id),
                "coverage_name": (coverage.coverage_name_snapshot if coverage else "해당 담보"),
                "insured_amount": coverage.insured_amount if coverage else 0,
                "eligibility_result": ass.eligibility_result.value,
                "reason_summary": ass.reason_summary,
                "article_number": article_number,
                "article_title": article_title,
                "clause_text": clause_text,
                "calculation_status": calc_status,
                "payment_rate": payment_rate_str,
                "final_amount": final_amount,
                "formula": formula,
            }
        )

    # 4. Review & Adjuster Info
    review = None
    if review_id:
        review = db.scalar(select(Review).where(Review.review_id == review_id))
    if not review:
        review = db.scalar(
            select(Review).where(Review.claim_id == claim_id).order_by(Review.created_at.desc())
        )

    reviewer_user = None
    if review and review.reviewer_user_id:
        reviewer_user = db.scalar(select(User).where(User.user_id == review.reviewer_user_id))

    review_info = None
    if review:
        review_info = {
            "review_id": str(review.review_id),
            "review_status": review.review_status.value,
            "review_type": review.review_type.value,
            "reason": review.reason,
            "opinion": review.opinion,
            "completed_at": (review.completed_at.isoformat() if review.completed_at else None),
        }

    # Adjuster profile
    default_adjuster = {
        "name": (reviewer_user.display_name if reviewer_user else "공인 손해사정사"),
        "license_number": "제1종·제4종 손해사정사 (등록번호: 제2026-0818호)",
        "office_name": "바로 손해사정연구소 (Baro ClaimLens)",
        "contact": "02-1588-0000 / support@baroproject.local",
    }
    if adjuster_override:
        default_adjuster.update(adjuster_override)

    # 5. Documents
    docs_raw = list(
        db.scalars(
            select(MedicalDocument)
            .where(MedicalDocument.claim_id == claim_id)
            .order_by(MedicalDocument.uploaded_at)
        )
    )
    docs_list = []
    for d in docs_raw:
        docs_list.append(
            {
                "document_id": str(d.document_id),
                "document_type": d.document_type.value,
                "document_type_label": DOCUMENT_TYPE_LABELS.get(
                    d.document_type.value, d.document_type.value
                ),
                "original_filename": d.original_filename,
                "created_at": d.uploaded_at.isoformat(),
            }
        )

    report_number = f"RPT-{claim.claim_number}"
    total_korean = format_korean_currency(total_assessed_amount)

    return {
        "report_id": f"rpt_{claim.claim_id.hex[:12]}",
        "report_number": report_number,
        "claim_id": str(claim.claim_id),
        "claim_number": claim.claim_number,
        "created_at": claim.updated_at.isoformat() if claim.updated_at else "",
        "adjuster": default_adjuster,
        "insured": insured_info,
        "contract": contract_info,
        "incident": incident_info,
        "medical_facts": facts_list,
        "coverages": coverages_list,
        "total_assessed_amount": total_assessed_amount,
        "total_assessed_amount_korean": total_korean,
        "review": review_info,
        "documents": docs_list,
    }
