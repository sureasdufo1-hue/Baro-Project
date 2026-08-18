from fastapi import APIRouter, Depends
from sqlalchemy import text
from sqlalchemy.orm import Session

from infrastructure.database.session import get_db
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
