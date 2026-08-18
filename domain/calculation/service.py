import hashlib
import json
from datetime import date
from typing import Any
from uuid import UUID

from pydantic import ValidationError
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from domain.assessment.models import CoverageAssessment, EligibilityResult
from domain.assessment.service import owned_assessment
from domain.calculation.engine import CalculationRule, calculate
from domain.calculation.models import BenefitCalculation, CalculationStatus
from domain.claim.service import owned_claim
from domain.contract.models import ContractCoverage
from domain.fact.models import FactType, VerificationStatus, VerifiedFact
from domain.rule.models import BenefitRule, RuleStatus, RuleType, RuleVersion
from shared.errors import DomainError


def authoritative_facts(db: Session, claim_id: UUID) -> tuple[dict[str, str], list[str]]:
    rows = list(
        db.scalars(
            select(VerifiedFact).where(
                VerifiedFact.claim_id == claim_id,
                VerifiedFact.verification_status.in_(
                    [
                        VerificationStatus.USER_CONFIRMED,
                        VerificationStatus.USER_MODIFIED,
                        VerificationStatus.EXPERT_CONFIRMED,
                        VerificationStatus.EXPERT_MODIFIED,
                    ]
                ),
            )
        )
    )
    values: dict[str, str] = {}
    ids = []
    for row in rows:
        key = row.fact_type.value
        if key in values and values[key] != row.verified_value:
            raise DomainError("FACT_CONFLICT", "Verified facts conflict", 409)
        values[key] = row.verified_value
        ids.append(str(row.verified_fact_id))
    return values, sorted(ids)


def fingerprint(
    assessment: CoverageAssessment,
    coverage: ContractCoverage,
    rule_id: UUID | None,
    facts: dict[str, str],
    fact_ids: list[str],
) -> str:
    payload = {
        "assessment_id": str(assessment.assessment_id),
        "policy_version_id": str(assessment.policy_version_id),
        "rule_version_id": str(rule_id),
        "insured_amount": coverage.insured_amount,
        "coverage_dates": [str(coverage.coverage_start_date), str(coverage.coverage_end_date)],
        "fact_ids": fact_ids,
        "facts": facts,
    }
    return hashlib.sha256(
        json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def calculate_assessment(db: Session, assessment_id: UUID, user_id: UUID) -> BenefitCalculation:
    assessment = owned_assessment(db, assessment_id, user_id)
    coverage = db.get(ContractCoverage, assessment.contract_coverage_id)
    if coverage is None:
        raise DomainError("CONTRACT_COVERAGE_NOT_FOUND", "Coverage was not found", 404)
    facts, fact_ids = authoritative_facts(db, assessment.claim_id)
    if assessment.eligibility_result is EligibilityResult.NOT_PAYABLE:
        rule_id = None
    elif assessment.eligibility_result is EligibilityResult.PAYABLE:
        if assessment.policy_version_id is None:
            raise DomainError("CALCULATION_NOT_ALLOWED", "Policy version is unresolved", 409)
        rule_id = assessment.calculation_rule_version_id
        if rule_id is None:
            raise DomainError(
                "CALCULATION_RULE_NOT_FOUND", "Calculation rule was not resolved", 409
            )
    else:
        raise DomainError(
            "CALCULATION_NOT_ALLOWED", "Assessment is not eligible for calculation", 409
        )
    digest = fingerprint(assessment, coverage, rule_id, facts, fact_ids)
    existing = db.scalar(
        select(BenefitCalculation).where(
            BenefitCalculation.assessment_id == assessment_id,
            BenefitCalculation.calculation_fingerprint == digest,
        )
    )
    if existing:
        return existing
    current = db.scalar(
        select(BenefitCalculation)
        .where(
            BenefitCalculation.claim_id == assessment.claim_id,
            BenefitCalculation.contract_coverage_id == coverage.contract_coverage_id,
            BenefitCalculation.is_current.is_(True),
        )
        .order_by(BenefitCalculation.calculation_version.desc())
    )
    version_no = (
        int(
            db.scalar(
                select(func.coalesce(func.max(BenefitCalculation.calculation_version), 0)).where(
                    BenefitCalculation.claim_id == assessment.claim_id,
                    BenefitCalculation.contract_coverage_id == coverage.contract_coverage_id,
                )
            )
            or 0
        )
        + 1
    )
    if assessment.eligibility_result is EligibilityResult.NOT_PAYABLE:
        result_gross = result_final = 0
        deduction = 0
        rate = None
        formula = "not_payable_assessment"
        inputs: dict[str, Any] = {"eligibility_result": "NOT_PAYABLE"}
        status = CalculationStatus.NOT_PAYABLE
    else:
        assert rule_id is not None
        pair = db.execute(
            select(BenefitRule, RuleVersion)
            .join(RuleVersion)
            .where(
                RuleVersion.rule_version_id == rule_id,
                RuleVersion.status == RuleStatus.ACTIVE,
                BenefitRule.rule_id == RuleVersion.rule_id,
                BenefitRule.rule_type == RuleType.CALCULATION,
                BenefitRule.status == RuleStatus.ACTIVE,
            )
        ).one_or_none()
        if pair is None:
            raise DomainError(
                "CALCULATION_RULE_NOT_FOUND", "Active calculation rule was not found", 409
            )
        try:
            parsed = CalculationRule.model_validate(pair[1].rule_definition)
        except ValidationError as exc:
            raise DomainError(
                "INVALID_CALCULATION_RULE", "Calculation rule is invalid", 422
            ) from exc

        def parsed_date(kind: FactType) -> date | None:
            value = facts.get(kind.value)
            if not value:
                return None
            try:
                return date.fromisoformat(value)
            except ValueError:
                raise DomainError(
                    "INVALID_CALCULATION_INPUT", "Verified date is invalid", 422
                ) from None

        calculated = calculate(
            parsed,
            coverage.insured_amount,
            parsed_date(FactType.HOSPITAL_ADMISSION_DATE),
            parsed_date(FactType.HOSPITAL_DISCHARGE_DATE),
        )
        result_gross, result_final, deduction = (
            calculated.gross_amount,
            calculated.final_amount,
            calculated.deduction_amount,
        )
        rate, formula, inputs, status = (
            calculated.payment_rate,
            calculated.formula,
            calculated.inputs,
            CalculationStatus.CALCULATED,
        )
    if current:
        current.is_current = False
        current.calculation_status = CalculationStatus.SUPERSEDED
    item = BenefitCalculation(
        claim_id=assessment.claim_id,
        assessment_id=assessment.assessment_id,
        contract_coverage_id=coverage.contract_coverage_id,
        rule_version_id=rule_id,
        calculation_version=version_no,
        previous_calculation_id=current.calculation_id if current else None,
        is_current=True,
        calculation_fingerprint=digest,
        insured_amount_snapshot=coverage.insured_amount,
        payment_rate_snapshot=rate,
        calculation_formula=formula,
        calculation_input={
            "facts": facts,
            "verified_fact_ids": fact_ids,
            "parameters": inputs,
            "policy_version_id": str(assessment.policy_version_id),
        },
        gross_amount=result_gross,
        deduction_amount=deduction,
        final_amount=result_final,
        calculation_status=status,
    )
    db.add(item)
    db.flush()
    return item


def owned_calculation(db: Session, calculation_id: UUID, user_id: UUID) -> BenefitCalculation:
    item = db.get(BenefitCalculation, calculation_id)
    if item is None:
        raise DomainError("CALCULATION_NOT_FOUND", "Calculation was not found", 404)
    owned_claim(db, item.claim_id, user_id)
    return item


def calculation_view(item: BenefitCalculation) -> dict[str, Any]:
    return {
        "calculation_id": item.calculation_id,
        "claim_id": item.claim_id,
        "assessment_id": item.assessment_id,
        "calculation_version": item.calculation_version,
        "previous_calculation_id": item.previous_calculation_id,
        "is_current": item.is_current,
        "currency": item.currency,
        "insured_amount_snapshot": item.insured_amount_snapshot,
        "payment_rate_snapshot": item.payment_rate_snapshot,
        "calculation_formula": item.calculation_formula,
        "gross_amount": item.gross_amount,
        "deduction_amount": item.deduction_amount,
        "final_amount": item.final_amount,
        "calculation_status": item.calculation_status,
        "calculated_at": item.calculated_at,
    }
