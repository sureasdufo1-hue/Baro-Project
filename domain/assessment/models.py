import enum
import uuid
from datetime import datetime
from decimal import Decimal
from typing import Any

from sqlalchemy import JSON, DateTime, Enum, ForeignKey, Index, Numeric, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from domain.rule.models import RuleType
from domain.user.models import utc_now
from infrastructure.database.base import Base


class AssessmentStatus(enum.StrEnum):
    PENDING = "PENDING"
    EVALUATING = "EVALUATING"
    COMPLETED = "COMPLETED"
    FAILED = "FAILED"
    MANUAL_REVIEW = "MANUAL_REVIEW"


class EligibilityResult(enum.StrEnum):
    PAYABLE = "PAYABLE"
    LIKELY_PAYABLE = "LIKELY_PAYABLE"
    ADDITIONAL_INFO_REQUIRED = "ADDITIONAL_INFO_REQUIRED"
    MANUAL_REVIEW = "MANUAL_REVIEW"
    LIKELY_NOT_PAYABLE = "LIKELY_NOT_PAYABLE"
    POSSIBLE_EXCLUSION = "POSSIBLE_EXCLUSION"
    NOT_PAYABLE = "NOT_PAYABLE"
    UNDETERMINED = "UNDETERMINED"


class RuleEvaluationResult(enum.StrEnum):
    PASS = "PASS"
    FAIL = "FAIL"
    MISSING_INPUT = "MISSING_INPUT"
    ERROR = "ERROR"


class CoverageAssessment(Base):
    __tablename__ = "coverage_assessments"
    __table_args__ = (Index("ix_coverage_assessments_claim_created", "claim_id", "created_at"),)
    assessment_id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    claim_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("claims.claim_id"), index=True)
    contract_coverage_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("contract_coverages.contract_coverage_id"), index=True
    )
    policy_version_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("policy_versions.policy_version_id"), index=True
    )
    rule_version_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("rule_versions.rule_version_id")
    )
    calculation_rule_version_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("rule_versions.rule_version_id")
    )
    assessment_status: Mapped[AssessmentStatus] = mapped_column(Enum(AssessmentStatus), index=True)
    match_score: Mapped[Decimal] = mapped_column(Numeric(5, 4))
    eligibility_result: Mapped[EligibilityResult] = mapped_column(
        Enum(EligibilityResult), index=True
    )
    exclusion_result: Mapped[str | None] = mapped_column(String(100))
    reduction_result: Mapped[str | None] = mapped_column(String(100))
    reason_summary: Mapped[str] = mapped_column(Text)
    resolution_snapshot: Mapped[dict[str, Any]] = mapped_column(JSON)
    assessed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utc_now, onupdate=utc_now
    )


class AssessmentRuleResult(Base):
    __tablename__ = "assessment_rule_results"
    result_id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    assessment_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("coverage_assessments.assessment_id"), index=True
    )
    rule_version_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("rule_versions.rule_version_id"), index=True
    )
    rule_type: Mapped[RuleType] = mapped_column(Enum(RuleType))
    result: Mapped[RuleEvaluationResult] = mapped_column(Enum(RuleEvaluationResult))
    input_snapshot: Mapped[dict[str, Any]] = mapped_column(JSON)
    execution_trace: Mapped[dict[str, Any]] = mapped_column(JSON)
    executed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
