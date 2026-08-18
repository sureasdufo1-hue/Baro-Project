from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session

from domain.audit.models import AuditEventType, AuditLog, AuditResult
from domain.user.models import User


def test_register_login_me_and_logout(
    client: TestClient, db_session: Session, registration_payload: dict[str, object]
) -> None:
    registered = client.post("/api/auth/register", json=registration_payload)
    assert registered.status_code == 201
    assert "password" not in registered.text.lower()
    stored = db_session.scalar(select(User).where(User.email == "user@example.com"))
    assert stored is not None
    assert stored.password_hash != registration_payload["password"]

    logged_in = client.post(
        "/api/auth/login",
        json={"email": registration_payload["email"], "password": registration_payload["password"]},
    )
    assert logged_in.status_code == 200
    cookie = logged_in.headers["set-cookie"]
    assert "HttpOnly" in cookie
    assert "SameSite=strict" in cookie
    assert client.get("/api/auth/me").status_code == 200
    replay_token = client.cookies.get("claimlens_session")
    assert replay_token is not None
    assert client.post("/api/auth/logout").status_code == 200
    assert client.get("/api/auth/me").status_code == 401
    client.cookies.set("claimlens_session", replay_token)
    assert client.get("/api/auth/me").status_code == 401

    events = list(db_session.scalars(select(AuditLog.event_type)))
    assert AuditEventType.USER_REGISTER in events
    assert AuditEventType.LOGIN in events
    assert AuditEventType.LOGOUT in events


def test_failed_login_is_rejected_and_audited(
    client: TestClient, db_session: Session, registration_payload: dict[str, object]
) -> None:
    client.post("/api/auth/register", json=registration_payload)
    response = client.post(
        "/api/auth/login", json={"email": "user@example.com", "password": "wrong"}
    )
    assert response.status_code == 401
    event = db_session.scalar(
        select(AuditLog).where(AuditLog.event_type == AuditEventType.LOGIN_FAIL)
    )
    assert event is not None
    assert event.result is AuditResult.FAILURE


def test_required_consents_are_enforced(
    client: TestClient, registration_payload: dict[str, object]
) -> None:
    registration_payload["consents"] = []
    response = client.post("/api/auth/register", json=registration_payload)
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "VALIDATION_ERROR"
