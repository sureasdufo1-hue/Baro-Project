from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from uuid import UUID

import jwt


@dataclass(frozen=True)
class SessionClaims:
    user_id: UUID
    session_id: UUID


def create_session_token(user_id: UUID, session_id: UUID, secret: str, ttl_seconds: int) -> str:
    now = datetime.now(UTC)
    payload = {
        "sub": str(user_id),
        "sid": str(session_id),
        "iat": now,
        "exp": now + timedelta(seconds=ttl_seconds),
    }
    return jwt.encode(payload, secret, algorithm="HS256")


def decode_session_token(token: str, secret: str) -> SessionClaims:
    payload = jwt.decode(token, secret, algorithms=["HS256"])
    return SessionClaims(UUID(payload["sub"]), UUID(payload["sid"]))
