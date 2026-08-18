from fastapi import APIRouter, Depends, Response
from sqlalchemy import text
from sqlalchemy.orm import Session

from apps.api.app.dependencies import require_role
from domain.user.models import User, UserRole
from infrastructure.database.session import get_db
from infrastructure.observability.metrics import metrics
from shared.errors import DomainError

router = APIRouter(tags=["health"])


@router.get("/health/live")
def live() -> dict[str, str]:
    return {"status": "ok"}


@router.get("/health/ready")
def ready(db: Session = Depends(get_db)) -> dict[str, str]:
    try:
        db.execute(text("SELECT 1"))
    except Exception:
        raise DomainError("DEPENDENCY_UNAVAILABLE", "Database is unavailable", 503) from None
    return {"status": "ready"}


@router.get("/metrics", response_class=Response)
def application_metrics(
    _: User = Depends(require_role(UserRole.SECURITY_ADMIN, UserRole.SYSTEM_ADMIN)),
) -> Response:
    return Response(metrics.render(), media_type="text/plain; version=0.0.4")
