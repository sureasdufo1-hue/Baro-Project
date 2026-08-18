from typing import Any
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.orm import Session

from domain.assessment.models import AssessmentRuleResult, CoverageAssessment, EligibilityResult
from domain.calculation.models import BenefitCalculation, CalculationStatus
from domain.calculation.service import owned_calculation
from domain.claim.models import Claim, ClaimStatus
from domain.claim.service import ClaimStateMachine
from domain.contract.models import ContractCoverage
from domain.document.models import MedicalDocument
from domain.evidence.models import Evidence, EvidenceRole, EvidenceType
from domain.fact.models import ExtractedFact, OCRResult, VerifiedFact
from domain.policy.models import PolicyClause, PolicyVersion
from domain.rule.models import BenefitRule, BenefitRuleClause, RuleVersion
from shared.errors import DomainError


def _add(
    db: Session,
    calculation: BenefitCalculation,
    evidence_type: EvidenceType,
    source_id: UUID,
    role: EvidenceRole,
    summary: str,
    **values: Any,
) -> Evidence:
    item = Evidence(
        claim_id=calculation.claim_id,
        assessment_id=calculation.assessment_id,
        calculation_id=calculation.calculation_id,
        evidence_version=calculation.calculation_version,
        evidence_type=evidence_type,
        source_id=source_id,
        evidence_role=role,
        summary=summary,
        source_snapshot=values.pop("source_snapshot", {}),
        **values,
    )
    db.add(item)
    return item


def build_for_calculation(db: Session, calculation_id: UUID, user_id: UUID) -> list[Evidence]:
    calculation = owned_calculation(db, calculation_id, user_id)
    existing = list(db.scalars(select(Evidence).where(Evidence.calculation_id == calculation_id)))
    if existing:
        validate_evidence_chain(calculation, existing)
        return existing
    assessment = db.get(CoverageAssessment, calculation.assessment_id)
    coverage = db.get(ContractCoverage, calculation.contract_coverage_id)
    if assessment is None or coverage is None or assessment.claim_id != calculation.claim_id:
        raise DomainError("EVIDENCE_SOURCE_MISMATCH", "Calculation sources do not match", 409)
    if assessment.policy_version_id is None:
        raise DomainError("EVIDENCE_POLICY_VERSION_MISSING", "Policy version is missing", 409)
    policy_version = db.get(PolicyVersion, assessment.policy_version_id)
    if policy_version is None:
        raise DomainError("EVIDENCE_POLICY_VERSION_MISSING", "Policy version is missing", 409)

    records = [
        _add(
            db,
            calculation,
            EvidenceType.CONTRACT,
            coverage.contract_id,
            EvidenceRole.SUPPORTS_AMOUNT,
            "계산에 적용된 보험계약",
            contract_coverage_id=coverage.contract_coverage_id,
        ),
        _add(
            db,
            calculation,
            EvidenceType.COVERAGE,
            coverage.contract_coverage_id,
            EvidenceRole.SUPPORTS_AMOUNT,
            "계산 당시 가입담보와 가입금액",
            contract_coverage_id=coverage.contract_coverage_id,
            source_snapshot={
                "coverage_name": coverage.coverage_name_snapshot,
                "insured_amount": calculation.insured_amount_snapshot,
            },
        ),
        _add(
            db,
            calculation,
            EvidenceType.POLICY,
            policy_version.policy_version_id,
            EvidenceRole.SUPPORTS_ELIGIBILITY,
            "판단에 적용된 약관 버전",
            policy_version_id=policy_version.policy_version_id,
            source_snapshot={"version_code": policy_version.version_code},
        ),
        _add(
            db,
            calculation,
            EvidenceType.CALCULATION,
            calculation.calculation_id,
            EvidenceRole.SUPPORTS_AMOUNT,
            "결정론적 계산 결과와 입력 스냅샷",
            source_snapshot={
                "formula": calculation.calculation_formula,
                "insured_amount": calculation.insured_amount_snapshot,
                "payment_rate": str(calculation.payment_rate_snapshot)
                if calculation.payment_rate_snapshot is not None
                else None,
                "final_amount": calculation.final_amount,
            },
        ),
    ]
    rule_ids = {
        value
        for value in (assessment.rule_version_id, calculation.rule_version_id)
        if value is not None
    }
    clause_count = 0
    for rule_version_id in rule_ids:
        pair = db.execute(
            select(RuleVersion, BenefitRule)
            .join(BenefitRule, BenefitRule.rule_id == RuleVersion.rule_id)
            .where(RuleVersion.rule_version_id == rule_version_id)
        ).one_or_none()
        if pair is None or pair.BenefitRule.policy_version_id != assessment.policy_version_id:
            raise DomainError("EVIDENCE_RULE_MISMATCH", "Rule policy version does not match", 409)
        records.append(
            _add(
                db,
                calculation,
                EvidenceType.RULE,
                rule_version_id,
                EvidenceRole.SUPPORTS_AMOUNT
                if rule_version_id == calculation.rule_version_id
                else EvidenceRole.SUPPORTS_ELIGIBILITY,
                "판단 또는 계산에 실행된 규칙 버전",
                policy_version_id=assessment.policy_version_id,
                rule_version_id=rule_version_id,
                source_snapshot={
                    "rule_name": pair.BenefitRule.rule_name,
                    "version_no": pair.RuleVersion.version_no,
                },
            )
        )
        clauses = list(
            db.scalars(
                select(PolicyClause)
                .join(BenefitRuleClause, BenefitRuleClause.clause_id == PolicyClause.clause_id)
                .where(BenefitRuleClause.rule_id == pair.BenefitRule.rule_id)
            )
        )
        for clause in clauses:
            if clause.policy_version_id != assessment.policy_version_id:
                raise DomainError(
                    "EVIDENCE_POLICY_VERSION_MISMATCH",
                    "Rule clause belongs to a different policy version",
                    409,
                )
            clause_count += 1
            records.append(
                _add(
                    db,
                    calculation,
                    EvidenceType.POLICY_CLAUSE,
                    clause.clause_id,
                    EvidenceRole.SUPPORTS_AMOUNT
                    if rule_version_id == calculation.rule_version_id
                    else EvidenceRole.SUPPORTS_ELIGIBILITY,
                    "규칙에 명시적으로 연결된 약관 조항",
                    policy_version_id=clause.policy_version_id,
                    policy_clause_id=clause.clause_id,
                    rule_version_id=rule_version_id,
                    page_number=clause.page_number,
                    source_bbox=clause.source_bbox,
                    source_snapshot={
                        "article_number": clause.article_number,
                        "article_title": clause.article_title,
                        "clause_text": clause.clause_text,
                        "text_hash": clause.text_hash,
                    },
                )
            )
    if calculation.calculation_status is CalculationStatus.CALCULATED and clause_count == 0:
        raise DomainError(
            "EVIDENCE_POLICY_CLAUSE_MISSING", "No rule-linked policy clause was found", 409
        )

    raw_ids = calculation.calculation_input.get("verified_fact_ids", [])
    for raw_id in raw_ids:
        try:
            fact_id = UUID(str(raw_id))
        except ValueError:
            raise DomainError("EVIDENCE_FACT_INVALID", "Fact reference is invalid", 409) from None
        fact = db.get(VerifiedFact, fact_id)
        if fact is None or fact.claim_id != calculation.claim_id:
            raise DomainError("EVIDENCE_CROSS_CLAIM", "Fact does not belong to the claim", 409)
        extracted = db.get(ExtractedFact, fact.extracted_fact_id)
        if extracted is None or extracted.claim_id != calculation.claim_id:
            raise DomainError(
                "EVIDENCE_FACT_PROVENANCE_MISSING", "Extracted fact provenance is missing", 409
            )
        ocr = db.get(OCRResult, extracted.ocr_result_id)
        if ocr is None or ocr.document_id != extracted.document_id:
            raise DomainError("EVIDENCE_OCR_PROVENANCE_MISSING", "OCR provenance is missing", 409)
        document = db.get(MedicalDocument, fact.source_document_id)
        if (
            document is None
            or document.claim_id != calculation.claim_id
            or extracted.document_id != document.document_id
        ):
            raise DomainError(
                "EVIDENCE_DOCUMENT_MISMATCH", "Fact document does not belong to the claim", 409
            )
        records.append(
            _add(
                db,
                calculation,
                EvidenceType.VERIFIED_FACT,
                fact.verified_fact_id,
                EvidenceRole.SUPPORTS_CALCULATION_INPUT,
                "계산에 실제 사용된 검증 사실",
                verified_fact_id=fact.verified_fact_id,
                document_id=document.document_id,
                page_number=fact.source_page,
                source_bbox=fact.source_bbox,
                source_snapshot={
                    "fact_type": fact.fact_type.value,
                    "verified_value": fact.verified_value,
                    "verification_status": fact.verification_status.value,
                },
            )
        )
        records.append(
            _add(
                db,
                calculation,
                EvidenceType.DOCUMENT,
                document.document_id,
                EvidenceRole.SUPPORTS_CALCULATION_INPUT,
                "검증 사실의 원본 의료문서",
                verified_fact_id=fact.verified_fact_id,
                document_id=document.document_id,
                page_number=fact.source_page,
                source_bbox=fact.source_bbox,
                source_snapshot={
                    "filename": document.original_filename,
                    "file_hash": document.file_hash,
                },
            )
        )
    db.flush()
    validate_evidence_chain(calculation, records)
    return records


def validate_evidence_chain(calculation: BenefitCalculation, records: list[Evidence]) -> None:
    types = {item.evidence_type for item in records}
    required = {
        EvidenceType.CONTRACT,
        EvidenceType.COVERAGE,
        EvidenceType.POLICY,
        EvidenceType.CALCULATION,
    }
    if calculation.calculation_status is CalculationStatus.CALCULATED:
        required |= {EvidenceType.RULE, EvidenceType.POLICY_CLAUSE}
        if calculation.calculation_input.get("verified_fact_ids"):
            required |= {EvidenceType.VERIFIED_FACT, EvidenceType.DOCUMENT}
    missing = required - types
    if missing:
        raise DomainError(
            "EVIDENCE_CHAIN_INCOMPLETE",
            f"Required evidence is missing: {', '.join(sorted(x.value for x in missing))}",
            409,
        )


def complete_claim_if_ready(db: Session, claim_id: UUID) -> bool:
    """Complete an automatic claim only when every latest coverage decision is reproducible."""
    claim = db.get(Claim, claim_id)
    if claim is None or claim.status is not ClaimStatus.ASSESSING:
        return False
    assessments = list(
        db.scalars(
            select(CoverageAssessment)
            .where(CoverageAssessment.claim_id == claim_id)
            .order_by(CoverageAssessment.created_at)
        )
    )
    latest_by_coverage = {item.contract_coverage_id: item for item in assessments}
    if not latest_by_coverage:
        return False
    for assessment in latest_by_coverage.values():
        if assessment.eligibility_result not in {
            EligibilityResult.PAYABLE,
            EligibilityResult.NOT_PAYABLE,
        }:
            return False
        calculation = db.scalar(
            select(BenefitCalculation).where(
                BenefitCalculation.assessment_id == assessment.assessment_id,
                BenefitCalculation.is_current.is_(True),
            )
        )
        if calculation is None or calculation.calculation_status not in {
            CalculationStatus.CALCULATED,
            CalculationStatus.NOT_PAYABLE,
        }:
            return False
        evidence = list(
            db.scalars(
                select(Evidence).where(Evidence.calculation_id == calculation.calculation_id)
            )
        )
        validate_evidence_chain(calculation, evidence)
    ClaimStateMachine.transition(claim, ClaimStatus.COMPLETED)
    return True


def evidence_view(item: Evidence) -> dict[str, Any]:
    return {
        "evidence_id": item.evidence_id,
        "evidence_version": item.evidence_version,
        "evidence_type": item.evidence_type,
        "evidence_role": item.evidence_role,
        "source_id": item.source_id,
        "policy_version_id": item.policy_version_id,
        "policy_clause_id": item.policy_clause_id,
        "rule_version_id": item.rule_version_id,
        "verified_fact_id": item.verified_fact_id,
        "document_id": item.document_id,
        "page_number": item.page_number,
        "source_bbox": item.source_bbox,
        "source_snapshot": item.source_snapshot,
        "summary": item.summary,
    }


def decision_trace(db: Session, calculation: BenefitCalculation) -> list[dict[str, Any]]:
    assessment = db.get(CoverageAssessment, calculation.assessment_id)
    if assessment is None:
        raise DomainError("ASSESSMENT_NOT_FOUND", "Assessment was not found", 404)
    steps: list[dict[str, Any]] = [
        {
            "sequence": 1,
            "step_type": "POLICY_RESOLUTION",
            "result": assessment.resolution_snapshot.get("policy_resolution"),
            "policy_version_id": assessment.policy_version_id,
        },
        {
            "sequence": 2,
            "step_type": "COVERAGE_MATCH",
            "result": "MATCHED",
            "contract_coverage_id": assessment.contract_coverage_id,
        },
    ]
    results = list(
        db.scalars(
            select(AssessmentRuleResult)
            .where(AssessmentRuleResult.assessment_id == assessment.assessment_id)
            .order_by(AssessmentRuleResult.executed_at)
        )
    )
    for result in results:
        steps.append(
            {
                "sequence": len(steps) + 1,
                "step_type": result.rule_type.value,
                "result": result.result.value,
                "rule_version_id": result.rule_version_id,
                "trace": result.execution_trace,
            }
        )
    steps.append(
        {
            "sequence": len(steps) + 1,
            "step_type": "CALCULATION",
            "result": calculation.calculation_status.value,
            "rule_version_id": calculation.rule_version_id,
            "formula": calculation.calculation_formula,
            "final_amount": calculation.final_amount,
        }
    )
    return steps
