from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.orm import Session

from apps.api.app.dependencies import require_role
from domain.user.models import User, UserRole
from infrastructure.database.session import get_db

router = APIRouter(prefix="/api/admin", tags=["admin"])


@router.get("/status")
def admin_status(
    _: User = Depends(require_role(UserRole.SYSTEM_ADMIN, UserRole.SECURITY_ADMIN)),
) -> dict[str, str]:
    return {"status": "authorized"}


@router.get("/adjusters")
def list_adjusters(
    _: User = Depends(require_role(UserRole.SYSTEM_ADMIN)),
    db: Session = Depends(get_db),
) -> list[dict[str, str]]:
    adjusters = db.scalars(select(User).where(User.role == UserRole.ADJUSTER).order_by(User.email))
    return [
        {
            "user_id": str(item.user_id),
            "email": item.email,
            "display_name": item.display_name,
        }
        for item in adjusters
    ]
