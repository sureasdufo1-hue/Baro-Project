from datetime import UTC, datetime

from fastapi import APIRouter, Depends, Request, Response, status
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from apps.api.app.audit import record_audit
from apps.api.app.config import Settings, get_settings
from apps.api.app.dependencies import require_authenticated_user
from apps.api.app.schemas import LoginRequest, MessageResponse, RegisterRequest, UserResponse
from domain.audit.models import AuditEventType, AuditResult
from domain.user.models import Consent, ConsentType, User, UserStatus
from infrastructure.database.session import get_db
from shared.errors import DomainError
from shared.security.passwords import hash_password, verify_password
from shared.security.session import create_session_token

router = APIRouter(prefix="/api/auth", tags=["auth"])
REQUIRED_CONSENTS = {ConsentType.SERVICE_TERMS, ConsentType.PRIVACY}


def request_metadata(request: Request) -> tuple[str, str | None]:
    source_ip = request.client.host if request.client else None
    return request.state.request_id, source_ip


@router.post("/register", response_model=UserResponse, status_code=status.HTTP_201_CREATED)
def register(payload: RegisterRequest, request: Request, db: Session = Depends(get_db)) -> User:
    accepted = {item.consent_type for item in payload.consents if item.agreed}
    if not REQUIRED_CONSENTS.issubset(accepted):
        raise DomainError("VALIDATION_ERROR", "Service terms and privacy consent are required", 422)
    user = User(
        email=payload.email.lower(),
        password_hash=hash_password(payload.password),
        display_name=payload.display_name,
        phone=payload.phone,
    )
    db.add(user)
    try:
        db.flush()
    except IntegrityError:
        db.rollback()
        raise DomainError("VALIDATION_ERROR", "Email is already registered", 409) from None
    now = datetime.now(UTC)
    for item in payload.consents:
        db.add(
            Consent(
                user_id=user.user_id,
                consent_type=item.consent_type,
                consent_version=item.consent_version,
                agreed=item.agreed,
                agreed_at=now if item.agreed else None,
                source_ip=request.client.host if request.client else None,
            )
        )
    request_id, source_ip = request_metadata(request)
    record_audit(
        db,
        event_type=AuditEventType.USER_REGISTER,
        result=AuditResult.SUCCESS,
        actor_user_id=user.user_id,
        object_type="User",
        object_id=str(user.user_id),
        request_id=request_id,
        source_ip=source_ip,
    )
    db.commit()
    db.refresh(user)
    return user


@router.post("/login", response_model=UserResponse)
def login(
    payload: LoginRequest,
    request: Request,
    response: Response,
    db: Session = Depends(get_db),
    settings: Settings = Depends(get_settings),
) -> User:
    user = db.scalar(select(User).where(User.email == payload.email.lower()))
    request_id, source_ip = request_metadata(request)
    if user is None or not verify_password(payload.password, user.password_hash):
        record_audit(
            db,
            event_type=AuditEventType.LOGIN_FAIL,
            result=AuditResult.FAILURE,
            actor_user_id=user.user_id if user else None,
            object_type="User",
            object_id=str(user.user_id) if user else None,
            request_id=request_id,
            source_ip=source_ip,
        )
        db.commit()
        raise DomainError("INVALID_CREDENTIALS", "Invalid email or password", 401)
    if user.status is UserStatus.LOCKED:
        raise DomainError("ACCOUNT_LOCKED", "Account is locked", 403)
    if user.status is not UserStatus.ACTIVE:
        raise DomainError("ACCESS_DENIED", "Account is unavailable", 403)
    record_audit(
        db,
        event_type=AuditEventType.LOGIN,
        result=AuditResult.SUCCESS,
        actor_user_id=user.user_id,
        object_type="User",
        object_id=str(user.user_id),
        request_id=request_id,
        source_ip=source_ip,
    )
    db.commit()
    token = create_session_token(
        user.user_id, settings.session_secret, settings.session_ttl_seconds
    )
    response.set_cookie(
        settings.session_cookie_name,
        token,
        max_age=settings.session_ttl_seconds,
        httponly=True,
        secure=settings.cookie_secure,
        samesite="lax",
        path="/",
    )
    return user


@router.post("/logout", response_model=MessageResponse)
def logout(
    request: Request,
    response: Response,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
    settings: Settings = Depends(get_settings),
) -> MessageResponse:
    request_id, source_ip = request_metadata(request)
    record_audit(
        db,
        event_type=AuditEventType.LOGOUT,
        result=AuditResult.SUCCESS,
        actor_user_id=user.user_id,
        object_type="User",
        object_id=str(user.user_id),
        request_id=request_id,
        source_ip=source_ip,
    )
    db.commit()
    response.delete_cookie(settings.session_cookie_name, path="/")
    return MessageResponse(message="Logged out")


@router.get("/me", response_model=UserResponse)
def me(user: User = Depends(require_authenticated_user)) -> User:
    return user
