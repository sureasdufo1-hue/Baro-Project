from datetime import UTC, datetime, timedelta
from uuid import UUID

import jwt


def create_session_token(user_id: UUID, secret: str, ttl_seconds: int) -> str:
    now = datetime.now(UTC)
    payload = {"sub": str(user_id), "iat": now, "exp": now + timedelta(seconds=ttl_seconds)}
    return jwt.encode(payload, secret, algorithm="HS256")


def decode_session_token(token: str, secret: str) -> UUID:
    payload = jwt.decode(token, secret, algorithms=["HS256"])
    return UUID(payload["sub"])
