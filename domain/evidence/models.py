import enum
import uuid
from datetime import datetime

from sqlalchemy import JSON, DateTime, Enum, ForeignKey, Index, Integer, Text
from sqlalchemy.orm import Mapped, mapped_column

from domain.user.models import utc_now
from infrastructure.database.base import Base


class EvidenceType(enum.StrEnum):
    CONTRACT = "CONTRACT"
    COVERAGE = "COVERAGE"
    POLICY = "POLICY"
    POLICY_CLAUSE = "POLICY_CLAUSE"
    RULE = "RULE"
    VERIFIED_FACT = "VERIFIED_FACT"
    DOCUMENT = "DOCUMENT"
    CALCULATION = "CALCULATION"


class EvidenceRole(enum.StrEnum):
    SUPPORTS_ELIGIBILITY = "SUPPORTS_ELIGIBILITY"
    SUPPORTS_EXCLUSION = "SUPPORTS_EXCLUSION"
    SUPPORTS_REDUCTION = "SUPPORTS_REDUCTION"
    SUPPORTS_LIMIT = "SUPPORTS_LIMIT"
    SUPPORTS_CALCULATION_INPUT = "SUPPORTS_CALCULATION_INPUT"
    SUPPORTS_AMOUNT = "SUPPORTS_AMOUNT"


class Evidence(Base):
    __tablename__ = "evidences"
    __table_args__ = (Index("ix_evidences_claim_calculation", "claim_id", "calculation_id"),)

    evidence_id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    claim_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("claims.claim_id"), index=True)
    assessment_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("coverage_assessments.assessment_id"), index=True
    )
    calculation_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("benefit_calculations.calculation_id"), index=True
    )
    evidence_version: Mapped[int] = mapped_column(Integer, default=1, index=True)
    evidence_type: Mapped[EvidenceType] = mapped_column(Enum(EvidenceType), index=True)
    source_id: Mapped[uuid.UUID] = mapped_column(index=True)
    evidence_role: Mapped[EvidenceRole] = mapped_column(Enum(EvidenceRole), index=True)
    contract_coverage_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("contract_coverages.contract_coverage_id"), index=True
    )
    policy_version_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("policy_versions.policy_version_id"), index=True
    )
    policy_clause_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("policy_clauses.clause_id"), index=True
    )
    rule_version_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("rule_versions.rule_version_id"), index=True
    )
    verified_fact_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("verified_facts.verified_fact_id"), index=True
    )
    document_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("medical_documents.document_id"), index=True
    )
    page_number: Mapped[int | None]
    source_bbox: Mapped[dict[str, object] | None] = mapped_column(JSON)
    source_snapshot: Mapped[dict[str, object]] = mapped_column(JSON, default=dict)
    summary: Mapped[str] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
