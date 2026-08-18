import enum
import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import JSON, DateTime, Enum, ForeignKey, String
from sqlalchemy.orm import Mapped, mapped_column

from domain.user.models import utc_now
from infrastructure.database.base import Base


class AuditEventType(enum.StrEnum):
    LOGIN = "LOGIN"
    LOGIN_FAIL = "LOGIN_FAIL"
    USER_REGISTER = "USER_REGISTER"
    LOGOUT = "LOGOUT"


class AuditResult(enum.StrEnum):
    SUCCESS = "SUCCESS"
    FAILURE = "FAILURE"


class AuditLog(Base):
    __tablename__ = "audit_logs"

    audit_id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    actor_user_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("users.user_id"), index=True)
    event_type: Mapped[AuditEventType] = mapped_column(Enum(AuditEventType), index=True)
    object_type: Mapped[str | None] = mapped_column(String(100))
    object_id: Mapped[str | None] = mapped_column(String(100))
    claim_id: Mapped[uuid.UUID | None] = mapped_column(index=True)
    request_id: Mapped[str] = mapped_column(String(100), index=True)
    source_ip: Mapped[str | None] = mapped_column(String(45))
    before_value: Mapped[dict[str, Any] | None] = mapped_column(JSON)
    after_value: Mapped[dict[str, Any] | None] = mapped_column(JSON)
    result: Mapped[AuditResult] = mapped_column(Enum(AuditResult))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
