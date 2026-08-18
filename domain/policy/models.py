import enum
import uuid
from datetime import date, datetime
from typing import Any

from sqlalchemy import (
    JSON,
    CheckConstraint,
    Date,
    DateTime,
    Enum,
    ForeignKey,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.orm import Mapped, mapped_column

from domain.user.models import utc_now
from infrastructure.database.base import Base


class MasterStatus(enum.StrEnum):
    ACTIVE = "ACTIVE"
    INACTIVE = "INACTIVE"


class VersionStatus(enum.StrEnum):
    DRAFT = "DRAFT"
    ACTIVE = "ACTIVE"
    DEPRECATED = "DEPRECATED"


class InsuranceType(enum.StrEnum):
    THIRD_PARTY = "THIRD_PARTY"
    LIFE = "LIFE"
    INDEMNITY = "INDEMNITY"
    AUTO = "AUTO"
    LIABILITY = "LIABILITY"
    WORKERS_COMP = "WORKERS_COMP"


class PolicyType(enum.StrEnum):
    GENERAL = "GENERAL"
    SPECIAL = "SPECIAL"
    RIDER = "RIDER"


class PolicyVersionStatus(enum.StrEnum):
    DRAFT = "DRAFT"
    PROCESSING = "PROCESSING"
    REVIEW_REQUIRED = "REVIEW_REQUIRED"
    APPROVED = "APPROVED"
    ACTIVE = "ACTIVE"
    DEPRECATED = "DEPRECATED"


class InsuranceCompany(Base):
    __tablename__ = "insurance_companies"
    company_id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    company_code: Mapped[str] = mapped_column(String(50), unique=True, index=True)
    company_name: Mapped[str] = mapped_column(String(200))
    company_type: Mapped[str] = mapped_column(String(50))
    status: Mapped[MasterStatus] = mapped_column(
        Enum(MasterStatus), default=MasterStatus.ACTIVE, index=True
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utc_now, onupdate=utc_now
    )


class InsuranceProduct(Base):
    __tablename__ = "insurance_products"
    __table_args__ = (
        UniqueConstraint("company_id", "product_code", name="uq_product_company_code"),
    )
    product_id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    company_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("insurance_companies.company_id"), index=True
    )
    product_code: Mapped[str] = mapped_column(String(80), index=True)
    product_name: Mapped[str] = mapped_column(String(200))
    insurance_type: Mapped[InsuranceType] = mapped_column(Enum(InsuranceType), index=True)
    status: Mapped[MasterStatus] = mapped_column(
        Enum(MasterStatus), default=MasterStatus.ACTIVE, index=True
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utc_now, onupdate=utc_now
    )


class ProductVersion(Base):
    __tablename__ = "product_versions"
    __table_args__ = (
        CheckConstraint(
            "sale_end_date IS NULL OR sale_start_date IS NULL OR sale_start_date <= sale_end_date",
            name="product_sale_period",
        ),
        CheckConstraint(
            "effective_to IS NULL OR effective_from IS NULL OR effective_from <= effective_to",
            name="product_effective_period",
        ),
        UniqueConstraint("product_id", "version_name", name="uq_product_version_name"),
    )
    product_version_id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    product_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("insurance_products.product_id"), index=True
    )
    version_name: Mapped[str] = mapped_column(String(80))
    sale_start_date: Mapped[date | None] = mapped_column(Date)
    sale_end_date: Mapped[date | None] = mapped_column(Date)
    effective_from: Mapped[date | None] = mapped_column(Date)
    effective_to: Mapped[date | None] = mapped_column(Date)
    status: Mapped[VersionStatus] = mapped_column(Enum(VersionStatus), default=VersionStatus.DRAFT)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utc_now, onupdate=utc_now
    )


class Policy(Base):
    __tablename__ = "policies"
    policy_id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    product_version_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("product_versions.product_version_id"), index=True
    )
    policy_name: Mapped[str] = mapped_column(String(250))
    policy_type: Mapped[PolicyType] = mapped_column(Enum(PolicyType))
    status: Mapped[MasterStatus] = mapped_column(Enum(MasterStatus), default=MasterStatus.ACTIVE)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utc_now, onupdate=utc_now
    )


class PolicyVersion(Base):
    __tablename__ = "policy_versions"
    __table_args__ = (
        CheckConstraint(
            "effective_to IS NULL OR effective_from <= effective_to", name="policy_effective_period"
        ),
        UniqueConstraint("policy_id", "version_code", name="uq_policy_version_code"),
    )
    policy_version_id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    policy_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("policies.policy_id"), index=True)
    version_code: Mapped[str] = mapped_column(String(80))
    effective_from: Mapped[date] = mapped_column(Date, index=True)
    effective_to: Mapped[date | None] = mapped_column(Date, index=True)
    published_date: Mapped[date | None] = mapped_column(Date)
    previous_version_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("policy_versions.policy_version_id")
    )
    file_hash: Mapped[str | None] = mapped_column(String(128))
    source_file_uri: Mapped[str | None] = mapped_column(String(1000))
    original_filename: Mapped[str | None] = mapped_column(String(255))
    status: Mapped[PolicyVersionStatus] = mapped_column(
        Enum(PolicyVersionStatus), default=PolicyVersionStatus.DRAFT, index=True
    )
    approved_by: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("users.user_id"))
    approved_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utc_now, onupdate=utc_now
    )


class PolicyClause(Base):
    __tablename__ = "policy_clauses"
    clause_id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    policy_version_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("policy_versions.policy_version_id"), index=True
    )
    article_number: Mapped[str | None] = mapped_column(String(80))
    article_title: Mapped[str | None] = mapped_column(String(300))
    paragraph_number: Mapped[str | None] = mapped_column(String(80))
    item_number: Mapped[str | None] = mapped_column(String(80))
    clause_text: Mapped[str] = mapped_column(Text)
    page_number: Mapped[int | None]
    source_bbox: Mapped[dict[str, Any] | None] = mapped_column(JSON)
    text_hash: Mapped[str | None] = mapped_column(String(128))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utc_now, onupdate=utc_now
    )


class Coverage(Base):
    __tablename__ = "coverages"
    coverage_id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    standard_code: Mapped[str] = mapped_column(String(80), unique=True, index=True)
    coverage_name: Mapped[str] = mapped_column(String(250))
    coverage_category: Mapped[str] = mapped_column(String(100), index=True)
    insurance_type: Mapped[InsuranceType] = mapped_column(Enum(InsuranceType), index=True)
    description: Mapped[str | None] = mapped_column(Text)
    status: Mapped[MasterStatus] = mapped_column(
        Enum(MasterStatus), default=MasterStatus.ACTIVE, index=True
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utc_now, onupdate=utc_now
    )


class CoverageAlias(Base):
    __tablename__ = "coverage_aliases"
    __table_args__ = (
        UniqueConstraint("coverage_id", "company_id", "normalized_name", name="uq_coverage_alias"),
    )
    alias_id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    coverage_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("coverages.coverage_id"), index=True)
    company_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("insurance_companies.company_id"), index=True
    )
    alias_name: Mapped[str] = mapped_column(String(250))
    normalized_name: Mapped[str] = mapped_column(String(250), index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
