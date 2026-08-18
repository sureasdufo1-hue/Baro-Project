from typing import Any
from uuid import UUID

from sqlalchemy.orm import Session

from domain.audit.models import AuditEventType, AuditLog, AuditResult


def record_audit(
    db: Session,
    *,
    event_type: AuditEventType,
    result: AuditResult,
    request_id: str,
    source_ip: str | None,
    actor_user_id: UUID | None = None,
    object_type: str | None = None,
    object_id: str | None = None,
    claim_id: UUID | None = None,
    before_value: dict[str, Any] | None = None,
    after_value: dict[str, Any] | None = None,
) -> None:
    db.add(
        AuditLog(
            actor_user_id=actor_user_id,
            event_type=event_type,
            result=result,
            request_id=request_id,
            source_ip=source_ip,
            object_type=object_type,
            object_id=object_id,
            claim_id=claim_id,
            before_value=before_value,
            after_value=after_value,
        )
    )
