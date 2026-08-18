import enum
import uuid
from datetime import date, datetime
from typing import Any

from sqlalchemy import JSON, Date, DateTime, Enum, ForeignKey, Integer, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from domain.user.models import utc_now
from infrastructure.database.base import Base


class RuleType(enum.StrEnum):
    ELIGIBILITY = "ELIGIBILITY"
    EXCLUSION = "EXCLUSION"
    REDUCTION = "REDUCTION"
    CALCULATION = "CALCULATION"
    LIMIT = "LIMIT"


class RuleStatus(enum.StrEnum):
    DRAFT = "DRAFT"
    AI_EXTRACTED = "AI_EXTRACTED"
    REVIEW_REQUIRED = "REVIEW_REQUIRED"
    TESTING = "TESTING"
    APPROVED = "APPROVED"
    ACTIVE = "ACTIVE"
    DEPRECATED = "DEPRECATED"


class RuleSourceType(enum.StrEnum):
    MANUAL = "MANUAL"
    AI_EXTRACTED = "AI_EXTRACTED"
    MIGRATED = "MIGRATED"


class RuleOperator(enum.StrEnum):
    EQ = "EQ"
    NE = "NE"
    GT = "GT"
    GTE = "GTE"
    LT = "LT"
    LTE = "LTE"
    IN = "IN"
    NOT_IN = "NOT_IN"
    BETWEEN = "BETWEEN"
    EXISTS = "EXISTS"
    NOT_EXISTS = "NOT_EXISTS"


class LogicalOperator(enum.StrEnum):
    AND = "AND"
    OR = "OR"


class BenefitRule(Base):
    __tablename__ = "benefit_rules"
    rule_id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    coverage_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("coverages.coverage_id"), index=True)
    policy_version_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("policy_versions.policy_version_id"), index=True
    )
    rule_name: Mapped[str] = mapped_column(String(250))
    rule_type: Mapped[RuleType] = mapped_column(Enum(RuleType))
    status: Mapped[RuleStatus] = mapped_column(
        Enum(RuleStatus), default=RuleStatus.DRAFT, index=True
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utc_now, onupdate=utc_now
    )


class RuleVersion(Base):
    __tablename__ = "rule_versions"
    __table_args__ = (UniqueConstraint("rule_id", "version_no", name="uq_rule_version_no"),)
    rule_version_id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    rule_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("benefit_rules.rule_id"), index=True)
    version_no: Mapped[int] = mapped_column(Integer)
    rule_definition: Mapped[dict[str, Any]] = mapped_column(JSON, default=dict)
    effective_from: Mapped[date | None] = mapped_column(Date)
    effective_to: Mapped[date | None] = mapped_column(Date)
    status: Mapped[RuleStatus] = mapped_column(
        Enum(RuleStatus), default=RuleStatus.DRAFT, index=True
    )
    source_type: Mapped[RuleSourceType] = mapped_column(Enum(RuleSourceType))
    created_by: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.user_id"))
    approved_by: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("users.user_id"))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    approved_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class RuleCondition(Base):
    __tablename__ = "rule_conditions"
    __table_args__ = (
        UniqueConstraint("rule_version_id", "sequence_no", name="uq_rule_condition_sequence"),
    )
    condition_id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    rule_version_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("rule_versions.rule_version_id"), index=True
    )
    sequence_no: Mapped[int] = mapped_column(Integer)
    fact_path: Mapped[str] = mapped_column(String(250))
    operator: Mapped[RuleOperator] = mapped_column(Enum(RuleOperator))
    comparison_value: Mapped[Any | None] = mapped_column(JSON)
    logical_operator: Mapped[LogicalOperator] = mapped_column(
        Enum(LogicalOperator), default=LogicalOperator.AND
    )


class BenefitRuleClause(Base):
    __tablename__ = "benefit_rule_clauses"
    __table_args__ = (UniqueConstraint("rule_id", "clause_id", name="uq_rule_clause"),)
    link_id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    rule_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("benefit_rules.rule_id"), index=True)
    clause_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("policy_clauses.clause_id"), index=True)
    relation_type: Mapped[str] = mapped_column(String(80), default="SOURCE")
