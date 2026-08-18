from collections.abc import Callable

import jwt
from fastapi import Depends, Request
from sqlalchemy.orm import Session

from apps.api.app.config import Settings, get_settings
from domain.user.models import User, UserRole, UserStatus
from infrastructure.database.session import get_db
from shared.errors import DomainError
from shared.security.session import decode_session_token


def require_authenticated_user(
    request: Request,
    db: Session = Depends(get_db),
    settings: Settings = Depends(get_settings),
) -> User:
    token = request.cookies.get(settings.session_cookie_name)
    if not token:
        raise DomainError("AUTHENTICATION_REQUIRED", "Authentication is required", 401)
    try:
        user_id = decode_session_token(token, settings.session_secret)
    except (jwt.PyJWTError, ValueError):
        raise DomainError("AUTHENTICATION_REQUIRED", "Invalid or expired session", 401) from None
    user = db.get(User, user_id)
    if user is None or user.status is not UserStatus.ACTIVE:
        raise DomainError("AUTHENTICATION_REQUIRED", "Active account not found", 401)
    return user


def require_role(*roles: UserRole) -> Callable[..., User]:
    def dependency(user: User = Depends(require_authenticated_user)) -> User:
        if user.role not in roles:
            raise DomainError("ACCESS_DENIED", "Insufficient permission", 403)
        return user

    return dependency
