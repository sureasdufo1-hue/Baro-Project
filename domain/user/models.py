import enum
import uuid
from datetime import UTC, datetime

from sqlalchemy import Boolean, DateTime, Enum, ForeignKey, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from infrastructure.database.base import Base


def utc_now() -> datetime:
    return datetime.now(UTC)


class UserRole(enum.StrEnum):
    USER = "USER"
    ADJUSTER = "ADJUSTER"
    POLICY_EDITOR = "POLICY_EDITOR"
    RULE_EDITOR = "RULE_EDITOR"
    RULE_APPROVER = "RULE_APPROVER"
    SECURITY_ADMIN = "SECURITY_ADMIN"
    SYSTEM_ADMIN = "SYSTEM_ADMIN"


class UserStatus(enum.StrEnum):
    ACTIVE = "ACTIVE"
    LOCKED = "LOCKED"
    DELETED = "DELETED"


class ConsentType(enum.StrEnum):
    SERVICE_TERMS = "SERVICE_TERMS"
    PRIVACY = "PRIVACY"
    SENSITIVE_INFORMATION = "SENSITIVE_INFORMATION"
    AI_PROCESSING = "AI_PROCESSING"


class User(Base):
    __tablename__ = "users"

    user_id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    email: Mapped[str] = mapped_column(String(320), unique=True, index=True)
    password_hash: Mapped[str] = mapped_column(String(512))
    display_name: Mapped[str] = mapped_column(String(100))
    phone: Mapped[str | None] = mapped_column(String(30))
    role: Mapped[UserRole] = mapped_column(Enum(UserRole), default=UserRole.USER)
    status: Mapped[UserStatus] = mapped_column(Enum(UserStatus), default=UserStatus.ACTIVE)
    mfa_enabled: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utc_now, onupdate=utc_now
    )
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    consents: Mapped[list["Consent"]] = relationship(back_populates="user")


class AuthSession(Base):
    __tablename__ = "auth_sessions"

    session_id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.user_id"), index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    last_used_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), index=True)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), index=True)
    source_ip: Mapped[str | None] = mapped_column(String(45))
    user_agent: Mapped[str | None] = mapped_column(String(300))


class Consent(Base):
    __tablename__ = "consents"
    __table_args__ = (
        UniqueConstraint("user_id", "consent_type", "consent_version", name="uq_consent_version"),
    )

    consent_id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.user_id"), index=True)
    consent_type: Mapped[ConsentType] = mapped_column(Enum(ConsentType))
    consent_version: Mapped[str] = mapped_column(String(50))
    agreed: Mapped[bool] = mapped_column(Boolean)
    agreed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    source_ip: Mapped[str | None] = mapped_column(String(45))
    user: Mapped[User] = relationship(back_populates="consents")
