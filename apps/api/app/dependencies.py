from collections.abc import Callable

import jwt
from fastapi import Depends, Request
from sqlalchemy import select
from sqlalchemy.orm import Session

from apps.api.app.config import Settings, get_settings
from domain.user.models import AuthSession, User, UserRole, UserStatus, utc_now
from infrastructure.ai.provider import (
    DevelopmentExtractionProvider,
    HTTPExtractionProvider,
    StructuredExtractionProvider,
)
from infrastructure.database.session import get_db
from infrastructure.ocr.provider import (
    DevelopmentOCRProvider,
    HTTPOCRProvider,
    OCRProvider,
    UnavailableOCRProvider,
)
from infrastructure.queue.ocr import OCRQueue, RQOCRQueue
from infrastructure.security.malware import (
    ClamAVMalwareScanner,
    DevelopmentMalwareScanner,
    MalwareScanner,
    UnavailableMalwareScanner,
)
from infrastructure.storage.object_storage import (
    LocalPrivateStorage,
    ObjectStorage,
    S3CompatibleObjectStorage,
)
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
        claims = decode_session_token(token, settings.session_secret)
    except (jwt.PyJWTError, ValueError):
        raise DomainError("AUTHENTICATION_REQUIRED", "Invalid or expired session", 401) from None
    session = db.scalar(
        select(AuthSession).where(
            AuthSession.session_id == claims.session_id,
            AuthSession.user_id == claims.user_id,
            AuthSession.revoked_at.is_(None),
            AuthSession.expires_at > utc_now(),
        )
    )
    if session is None:
        raise DomainError("AUTHENTICATION_REQUIRED", "Session is revoked or expired", 401)
    request.state.auth_session_id = session.session_id
    user = db.get(User, claims.user_id)
    if user is None or user.status is not UserStatus.ACTIVE:
        raise DomainError("AUTHENTICATION_REQUIRED", "Active account not found", 401)
    return user


def require_role(*roles: UserRole) -> Callable[..., User]:
    def dependency(user: User = Depends(require_authenticated_user)) -> User:
        if user.role not in roles:
            raise DomainError("ACCESS_DENIED", "Insufficient permission", 403)
        return user

    return dependency


def get_object_storage(settings: Settings = Depends(get_settings)) -> ObjectStorage:
    if settings.object_storage_provider == "LOCAL_PRIVATE":
        return LocalPrivateStorage(settings.local_object_storage_root)
    if settings.object_storage_provider == "S3":
        return S3CompatibleObjectStorage(
            settings.s3_bucket,
            settings.s3_region,
            settings.s3_endpoint_url,
            settings.s3_access_key_id,
            settings.s3_secret_access_key,
        )
    raise DomainError("STORAGE_UPLOAD_FAILED", "Object storage provider is not configured", 503)


def get_malware_scanner(settings: Settings = Depends(get_settings)) -> MalwareScanner:
    if settings.malware_scanner_provider == "DEVELOPMENT" and settings.app_env != "production":
        return DevelopmentMalwareScanner()
    if settings.malware_scanner_provider == "CLAMAV":
        return ClamAVMalwareScanner(
            settings.clamav_host, settings.clamav_port, settings.clamav_timeout_seconds
        )
    return UnavailableMalwareScanner()


def get_ocr_provider(settings: Settings = Depends(get_settings)) -> OCRProvider:
    if settings.ocr_provider == "DEVELOPMENT" and settings.app_env != "production":
        return DevelopmentOCRProvider()
    if settings.ocr_provider == "HTTP":
        return HTTPOCRProvider(
            settings.ocr_api_endpoint, settings.ocr_api_key, settings.ocr_timeout_seconds
        )
    return UnavailableOCRProvider()


def get_extraction_provider(
    settings: Settings = Depends(get_settings),
) -> StructuredExtractionProvider:
    if settings.ai_provider == "DEVELOPMENT" and settings.app_env != "production":
        return DevelopmentExtractionProvider()
    if settings.ai_provider == "HTTP":
        return HTTPExtractionProvider(
            settings.ai_api_endpoint, settings.ai_api_key, settings.ocr_timeout_seconds
        )
    raise DomainError("AI_PROVIDER_ERROR", "AI provider is not configured", 503)


def get_ocr_queue() -> OCRQueue:
    return RQOCRQueue()
