import enum
import uuid
from datetime import date, datetime

from sqlalchemy import BigInteger, CheckConstraint, Date, DateTime, Enum, ForeignKey, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from domain.user.models import utc_now
from infrastructure.database.base import Base


class Gender(enum.StrEnum):
    MALE = "MALE"
    FEMALE = "FEMALE"
    UNKNOWN = "UNKNOWN"


class RelationshipType(enum.StrEnum):
    SELF = "SELF"
    SPOUSE = "SPOUSE"
    CHILD = "CHILD"
    PARENT = "PARENT"
    OTHER = "OTHER"


class ContractStatus(enum.StrEnum):
    ACTIVE = "ACTIVE"
    EXPIRED = "EXPIRED"
    CANCELLED = "CANCELLED"
    SUSPENDED = "SUSPENDED"
    UNKNOWN = "UNKNOWN"


class RegistrationMethod(enum.StrEnum):
    MANUAL = "MANUAL"
    OCR = "OCR"
    ADMIN = "ADMIN"
    API = "API"


class CoverageStatus(enum.StrEnum):
    ACTIVE = "ACTIVE"
    EXPIRED = "EXPIRED"
    CANCELLED = "CANCELLED"


class Insured(Base):
    __tablename__ = "insureds"
    insured_id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    owner_user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.user_id"), index=True)
    name: Mapped[str] = mapped_column(String(100))
    birth_date: Mapped[date | None] = mapped_column(Date)
    gender: Mapped[Gender] = mapped_column(Enum(Gender), default=Gender.UNKNOWN)
    identity_token: Mapped[str | None] = mapped_column(String(255))
    relationship_type: Mapped[RelationshipType] = mapped_column(Enum(RelationshipType))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utc_now, onupdate=utc_now
    )


class InsuranceContract(Base):
    __tablename__ = "insurance_contracts"
    __table_args__ = (
        CheckConstraint(
            "coverage_start_date IS NULL OR contract_date IS NULL OR "
            "contract_date <= coverage_start_date",
            name="contract_start_after_contract",
        ),
        CheckConstraint(
            "coverage_end_date IS NULL OR coverage_start_date IS NULL OR "
            "coverage_start_date < coverage_end_date",
            name="contract_coverage_period",
        ),
    )
    contract_id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.user_id"), index=True)
    insured_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("insureds.insured_id"), index=True)
    product_version_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("product_versions.product_version_id"), index=True
    )
    policy_version_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("policy_versions.policy_version_id"), index=True
    )
    policy_number: Mapped[str | None] = mapped_column(String(150))
    contract_date: Mapped[date | None] = mapped_column(Date)
    coverage_start_date: Mapped[date | None] = mapped_column(Date)
    coverage_end_date: Mapped[date | None] = mapped_column(Date)
    contract_status: Mapped[ContractStatus] = mapped_column(
        Enum(ContractStatus), default=ContractStatus.ACTIVE, index=True
    )
    registration_method: Mapped[RegistrationMethod] = mapped_column(
        Enum(RegistrationMethod), default=RegistrationMethod.MANUAL
    )
    source_document_id: Mapped[uuid.UUID | None]
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utc_now, onupdate=utc_now
    )
    coverages: Mapped[list["ContractCoverage"]] = relationship(
        back_populates="contract", cascade="all, delete-orphan"
    )


class ContractCoverage(Base):
    __tablename__ = "contract_coverages"
    __table_args__ = (
        CheckConstraint("insured_amount >= 0", name="nonnegative_insured_amount"),
        CheckConstraint(
            "payment_limit IS NULL OR payment_limit >= 0", name="nonnegative_payment_limit"
        ),
        CheckConstraint(
            "payment_count_limit IS NULL OR payment_count_limit >= 0",
            name="nonnegative_payment_count",
        ),
        CheckConstraint(
            "coverage_end_date IS NULL OR coverage_start_date IS NULL OR "
            "coverage_start_date < coverage_end_date",
            name="contract_coverage_item_period",
        ),
    )
    contract_coverage_id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    contract_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("insurance_contracts.contract_id"), index=True
    )
    coverage_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("coverages.coverage_id"), index=True)
    coverage_name_snapshot: Mapped[str] = mapped_column(String(250))
    insured_amount: Mapped[int] = mapped_column(BigInteger)
    coverage_start_date: Mapped[date | None] = mapped_column(Date)
    coverage_end_date: Mapped[date | None] = mapped_column(Date)
    payment_limit: Mapped[int | None] = mapped_column(BigInteger)
    payment_count_limit: Mapped[int | None]
    status: Mapped[CoverageStatus] = mapped_column(
        Enum(CoverageStatus), default=CoverageStatus.ACTIVE, index=True
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utc_now, onupdate=utc_now
    )
    contract: Mapped[InsuranceContract] = relationship(back_populates="coverages")
