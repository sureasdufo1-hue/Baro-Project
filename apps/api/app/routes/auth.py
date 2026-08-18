from datetime import UTC, datetime, timedelta
from uuid import UUID

from fastapi import APIRouter, Depends, Request, Response, status
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from apps.api.app.audit import record_audit
from apps.api.app.config import Settings, get_settings
from apps.api.app.dependencies import require_authenticated_user, require_role
from apps.api.app.schemas import LoginRequest, MessageResponse, RegisterRequest, UserResponse
from domain.audit.models import AuditEventType, AuditResult
from domain.user.models import AuthSession, Consent, ConsentType, User, UserRole, UserStatus
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
    auth_session = AuthSession(
        user_id=user.user_id,
        expires_at=datetime.now(UTC) + timedelta(seconds=settings.session_ttl_seconds),
        source_ip=source_ip,
        user_agent=request.headers.get("user-agent", "")[:300] or None,
    )
    db.add(auth_session)
    db.commit()
    token = create_session_token(
        user.user_id,
        auth_session.session_id,
        settings.session_secret,
        settings.session_ttl_seconds,
    )
    response.set_cookie(
        settings.session_cookie_name,
        token,
        max_age=settings.session_ttl_seconds,
        httponly=True,
        secure=settings.cookie_secure,
        samesite="strict",
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
    auth_session = db.get(AuthSession, request.state.auth_session_id)
    if auth_session is not None:
        auth_session.revoked_at = datetime.now(UTC)
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


@router.post("/logout-all", response_model=MessageResponse)
def logout_all(
    request: Request,
    response: Response,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
    settings: Settings = Depends(get_settings),
) -> MessageResponse:
    sessions = list(
        db.scalars(
            select(AuthSession).where(
                AuthSession.user_id == user.user_id, AuthSession.revoked_at.is_(None)
            )
        )
    )
    now = datetime.now(UTC)
    for item in sessions:
        item.revoked_at = now
    request_id, source_ip = request_metadata(request)
    record_audit(
        db,
        event_type=AuditEventType.SESSION_REVOKE,
        result=AuditResult.SUCCESS,
        actor_user_id=user.user_id,
        object_type="User",
        object_id=str(user.user_id),
        request_id=request_id,
        source_ip=source_ip,
        after_value={"revoked_session_count": len(sessions)},
    )
    db.commit()
    response.delete_cookie(settings.session_cookie_name, path="/")
    return MessageResponse(message="All sessions revoked")


@router.get("/sessions", response_model=None)
def sessions(
    user: User = Depends(require_authenticated_user), db: Session = Depends(get_db)
) -> list[dict[str, object]]:
    return [
        {
            "session_id": item.session_id,
            "created_at": item.created_at,
            "last_used_at": item.last_used_at,
            "expires_at": item.expires_at,
            "revoked_at": item.revoked_at,
            "source_ip": item.source_ip,
            "user_agent": item.user_agent,
        }
        for item in db.scalars(
            select(AuthSession)
            .where(AuthSession.user_id == user.user_id)
            .order_by(AuthSession.created_at.desc())
        )
    ]


@router.post("/refresh", response_model=MessageResponse)
def refresh(
    request: Request,
    response: Response,
    _: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
    settings: Settings = Depends(get_settings),
) -> MessageResponse:
    auth_session = db.get(AuthSession, request.state.auth_session_id)
    if auth_session is None or auth_session.revoked_at is not None:
        raise DomainError("AUTHENTICATION_REQUIRED", "Session is revoked", 401)
    now = datetime.now(UTC)
    auth_session.last_used_at = now
    auth_session.expires_at = now + timedelta(seconds=settings.session_ttl_seconds)
    token = create_session_token(
        auth_session.user_id,
        auth_session.session_id,
        settings.session_secret,
        settings.session_ttl_seconds,
    )
    db.commit()
    response.set_cookie(
        settings.session_cookie_name,
        token,
        max_age=settings.session_ttl_seconds,
        httponly=True,
        secure=settings.cookie_secure,
        samesite="strict",
        path="/",
    )
    return MessageResponse(message="Session refreshed")


@router.delete("/sessions/{session_id}", response_model=MessageResponse)
def revoke_session(
    session_id: UUID,
    request: Request,
    response: Response,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
    settings: Settings = Depends(get_settings),
) -> MessageResponse:
    item = db.get(AuthSession, session_id)
    if item is None or item.user_id != user.user_id:
        raise DomainError("SESSION_NOT_FOUND", "Session was not found", 404)
    item.revoked_at = datetime.now(UTC)
    db.commit()
    if session_id == request.state.auth_session_id:
        response.delete_cookie(settings.session_cookie_name, path="/")
    return MessageResponse(message="Session revoked")


@router.post("/admin/users/{user_id}/revoke-sessions", response_model=MessageResponse)
def admin_revoke_sessions(
    user_id: UUID,
    request: Request,
    admin: User = Depends(require_role(UserRole.SECURITY_ADMIN, UserRole.SYSTEM_ADMIN)),
    db: Session = Depends(get_db),
) -> MessageResponse:
    target = db.get(User, user_id)
    if target is None:
        raise DomainError("USER_NOT_FOUND", "User was not found", 404)
    sessions = list(
        db.scalars(
            select(AuthSession).where(
                AuthSession.user_id == user_id, AuthSession.revoked_at.is_(None)
            )
        )
    )
    now = datetime.now(UTC)
    for item in sessions:
        item.revoked_at = now
    request_id, source_ip = request_metadata(request)
    record_audit(
        db,
        event_type=AuditEventType.SESSION_REVOKE,
        result=AuditResult.SUCCESS,
        actor_user_id=admin.user_id,
        object_type="User",
        object_id=str(user_id),
        request_id=request_id,
        source_ip=source_ip,
        after_value={"revoked_session_count": len(sessions), "admin_forced": True},
    )
    db.commit()
    return MessageResponse(message=f"Revoked {len(sessions)} sessions")


@router.get("/me", response_model=UserResponse)
def me(user: User = Depends(require_authenticated_user)) -> User:
    return user
