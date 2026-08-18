from fastapi import APIRouter, Depends

from apps.api.app.dependencies import require_role
from domain.user.models import User, UserRole

router = APIRouter(prefix="/api/admin", tags=["admin"])


@router.get("/status")
def admin_status(
    _: User = Depends(require_role(UserRole.SYSTEM_ADMIN, UserRole.SECURITY_ADMIN)),
) -> dict[str, str]:
    return {"status": "authorized"}
