import enum
import uuid
from datetime import datetime
from decimal import Decimal
from typing import Any

from sqlalchemy import (
    JSON,
    BigInteger,
    Boolean,
    DateTime,
    Enum,
    ForeignKey,
    Integer,
    Numeric,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.orm import Mapped, mapped_column

from domain.user.models import utc_now
from infrastructure.database.base import Base


class CalculationStatus(enum.StrEnum):
    PENDING = "PENDING"
    CALCULATED = "CALCULATED"
    NOT_PAYABLE = "NOT_PAYABLE"
    MANUAL_REVIEW = "MANUAL_REVIEW"
    FAILED = "FAILED"
    SUPERSEDED = "SUPERSEDED"


class BenefitCalculation(Base):
    __tablename__ = "benefit_calculations"
    __table_args__ = (
        UniqueConstraint(
            "assessment_id", "calculation_fingerprint", name="uq_calculation_fingerprint"
        ),
        UniqueConstraint("assessment_id", "calculation_version", name="uq_calculation_version"),
    )
    calculation_id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    claim_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("claims.claim_id"), index=True)
    assessment_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("coverage_assessments.assessment_id"), index=True
    )
    contract_coverage_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("contract_coverages.contract_coverage_id"), index=True
    )
    rule_version_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("rule_versions.rule_version_id"), index=True
    )
    calculation_version: Mapped[int] = mapped_column(Integer)
    previous_calculation_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("benefit_calculations.calculation_id")
    )
    is_current: Mapped[bool] = mapped_column(Boolean, default=True, index=True)
    calculation_fingerprint: Mapped[str] = mapped_column(String(64))
    currency: Mapped[str] = mapped_column(String(3), default="KRW")
    insured_amount_snapshot: Mapped[int] = mapped_column(BigInteger)
    payment_rate_snapshot: Mapped[Decimal | None] = mapped_column(Numeric(12, 6))
    calculation_formula: Mapped[str] = mapped_column(Text)
    calculation_input: Mapped[dict[str, Any]] = mapped_column(JSON)
    gross_amount: Mapped[int] = mapped_column(BigInteger)
    deduction_amount: Mapped[int] = mapped_column(BigInteger)
    final_amount: Mapped[int] = mapped_column(BigInteger)
    calculation_status: Mapped[CalculationStatus] = mapped_column(
        Enum(CalculationStatus), index=True
    )
    calculated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
