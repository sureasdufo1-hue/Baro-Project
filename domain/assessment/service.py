from datetime import date
from decimal import Decimal
from typing import Any
from uuid import UUID

from pydantic import ValidationError
from sqlalchemy import select
from sqlalchemy.orm import Session

from domain.assessment.engine import (
    Evaluation,
    ResolutionStatus,
    RuleDSL,
    aggregate,
    execute,
    resolve_policy_version,
)
from domain.assessment.models import (
    AssessmentRuleResult,
    AssessmentStatus,
    CoverageAssessment,
    EligibilityResult,
    RuleEvaluationResult,
)
from domain.claim.models import Claim, ClaimStatus
from domain.claim.service import ClaimStateMachine, owned_claim
from domain.contract.models import ContractCoverage, InsuranceContract
from domain.fact.models import FactType, VerificationStatus, VerifiedFact
from domain.policy.models import Policy, PolicyVersion, PolicyVersionStatus
from domain.rule.models import BenefitRule, RuleStatus, RuleType, RuleVersion
from shared.errors import DomainError


def verified_context(db: Session, claim_id: UUID) -> tuple[dict[str, Any], bool]:
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
    grouped: dict[FactType, set[str]] = {}
    for row in rows:
        grouped.setdefault(row.fact_type, set()).add(row.verified_value)
    conflict = any(len(values) > 1 for values in grouped.values())
    return {
        f"facts.{kind.value}": next(iter(values))
        for kind, values in grouped.items()
        if len(values) == 1
    }, conflict


def resolution_date(
    claim: Claim, facts: dict[str, Any], contract: InsuranceContract
) -> date | None:
    for key in ("facts.DIAGNOSIS_DATE", "facts.ACCIDENT_DATE"):
        if key in facts:
            try:
                return date.fromisoformat(str(facts[key]))
            except ValueError:
                return None
    return (
        claim.accident.diagnosis_date
        or claim.accident.accident_date
        or claim.accident.onset_date
        or contract.contract_date
    )


def create_assessments(db: Session, claim_id: UUID, user_id: UUID) -> list[CoverageAssessment]:
    claim = owned_claim(db, claim_id, user_id)
    if claim.status is not ClaimStatus.USER_VERIFICATION:
        raise DomainError("INVALID_CLAIM_STATE", "Claim is not ready for assessment", 409)
    contract = db.get(InsuranceContract, claim.contract_id)
    if contract is None:
        raise DomainError("INSURANCE_CONTRACT_NOT_FOUND", "Contract was not found", 404)
    facts, fact_conflict = verified_context(db, claim_id)
    candidates = list(
        db.scalars(
            select(PolicyVersion)
            .join(Policy)
            .where(
                Policy.product_version_id == contract.product_version_id,
                PolicyVersion.status == PolicyVersionStatus.ACTIVE,
            )
        )
    )
    resolution = resolve_policy_version(
        contract.policy_version_id, candidates, resolution_date(claim, facts, contract)
    )
    coverages = list(
        db.scalars(
            select(ContractCoverage).where(ContractCoverage.contract_id == contract.contract_id)
        )
    )
    if not coverages:
        raise DomainError("NO_CONTRACT_COVERAGE", "Contract has no subscribed coverage", 409)
    ClaimStateMachine.transition(claim, ClaimStatus.ASSESSING)
    assessments: list[CoverageAssessment] = []
    for coverage in coverages:
        snapshot = {
            "policy_resolution": resolution.status.value,
            "candidate_ids": [str(x) for x in resolution.candidate_ids],
        }
        if resolution.status is not ResolutionStatus.RESOLVED or fact_conflict:
            reason = "Verified fact conflict" if fact_conflict else resolution.reason
            item = CoverageAssessment(
                claim_id=claim_id,
                contract_coverage_id=coverage.contract_coverage_id,
                policy_version_id=resolution.policy_version_id,
                rule_version_id=None,
                calculation_rule_version_id=None,
                assessment_status=AssessmentStatus.MANUAL_REVIEW,
                match_score=Decimal("1.0000"),
                eligibility_result=EligibilityResult.MANUAL_REVIEW,
                exclusion_result=None,
                reduction_result=None,
                reason_summary=reason,
                resolution_snapshot=snapshot,
            )
            db.add(item)
            assessments.append(item)
            continue
        rules = list(
            db.execute(
                select(BenefitRule, RuleVersion)
                .join(RuleVersion)
                .where(
                    BenefitRule.coverage_id == coverage.coverage_id,
                    BenefitRule.policy_version_id == resolution.policy_version_id,
                    BenefitRule.status == RuleStatus.ACTIVE,
                    RuleVersion.status == RuleStatus.ACTIVE,
                )
            ).all()
        )
        calculation = [version for rule, version in rules if rule.rule_type is RuleType.CALCULATION]
        executable = [
            (rule, version) for rule, version in rules if rule.rule_type is not RuleType.CALCULATION
        ]
        primary = executable[0][1] if executable else None
        assessment = CoverageAssessment(
            claim_id=claim_id,
            contract_coverage_id=coverage.contract_coverage_id,
            policy_version_id=resolution.policy_version_id,
            rule_version_id=primary.rule_version_id if primary else None,
            calculation_rule_version_id=calculation[0].rule_version_id
            if len(calculation) == 1
            else None,
            assessment_status=AssessmentStatus.EVALUATING,
            match_score=Decimal("1.0000"),
            eligibility_result=EligibilityResult.UNDETERMINED,
            exclusion_result=None,
            reduction_result=None,
            reason_summary="Evaluation pending",
            resolution_snapshot=snapshot,
        )
        db.add(assessment)
        db.flush()
        evaluations: list[tuple[RuleType, RuleEvaluationResult]] = []
        invalid = False
        context = dict(facts)
        context.update(
            {
                "coverage.insuredAmount": coverage.insured_amount,
                "coverage.startDate": coverage.coverage_start_date.isoformat()
                if coverage.coverage_start_date
                else None,
                "contract.contractDate": contract.contract_date.isoformat()
                if contract.contract_date
                else None,
            }
        )
        for rule, version in executable:
            try:
                parsed = RuleDSL.model_validate(version.rule_definition)
                if parsed.rule_type is not rule.rule_type:
                    raise ValueError("rule type mismatch")
                evaluated = execute(parsed, context)
            except (ValidationError, ValueError, TypeError):
                invalid = True
                evaluated = Evaluation(
                    RuleEvaluationResult.ERROR, {}, {"error": "INVALID_RULE_DEFINITION"}
                )
            evaluations.append((rule.rule_type, evaluated.result))
            db.add(
                AssessmentRuleResult(
                    assessment_id=assessment.assessment_id,
                    rule_version_id=version.rule_version_id,
                    rule_type=rule.rule_type,
                    result=evaluated.result,
                    input_snapshot=evaluated.inputs,
                    execution_trace=evaluated.trace,
                )
            )
        assessment.eligibility_result = aggregate(evaluations)
        assessment.assessment_status = (
            AssessmentStatus.MANUAL_REVIEW
            if invalid or not executable
            else AssessmentStatus.COMPLETED
        )
        assessment.reason_summary = (
            "Manual review required"
            if assessment.assessment_status is AssessmentStatus.MANUAL_REVIEW
            else f"Deterministic rule result: {assessment.eligibility_result.value}"
        )
        assessments.append(assessment)
    db.flush()
    results = {item.eligibility_result for item in assessments}
    if EligibilityResult.ADDITIONAL_INFO_REQUIRED in results:
        ClaimStateMachine.transition(claim, ClaimStatus.DOCUMENT_REQUIRED)
    elif EligibilityResult.MANUAL_REVIEW in results:
        ClaimStateMachine.transition(claim, ClaimStatus.MANUAL_REVIEW)
    return assessments


def owned_assessment(db: Session, assessment_id: UUID, user_id: UUID) -> CoverageAssessment:
    item = db.get(CoverageAssessment, assessment_id)
    if item is None:
        raise DomainError("ASSESSMENT_NOT_FOUND", "Assessment was not found", 404)
    owned_claim(db, item.claim_id, user_id)
    return item


def assessment_view(item: CoverageAssessment) -> dict[str, Any]:
    return {
        "assessment_id": item.assessment_id,
        "claim_id": item.claim_id,
        "contract_coverage_id": item.contract_coverage_id,
        "policy_version_id": item.policy_version_id,
        "assessment_status": item.assessment_status,
        "match_score": item.match_score,
        "eligibility_result": item.eligibility_result,
        "exclusion_result": item.exclusion_result,
        "reduction_result": item.reduction_result,
        "reason_summary": item.reason_summary,
        "assessed_at": item.assessed_at,
    }
