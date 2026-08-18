from fastapi.testclient import TestClient


def test_anonymous_and_regular_user_cannot_access_admin(
    client: TestClient, registration_payload: dict[str, object]
) -> None:
    assert client.get("/api/admin/status").status_code == 401
    client.post("/api/auth/register", json=registration_payload)
    client.post(
        "/api/auth/login",
        json={"email": registration_payload["email"], "password": registration_payload["password"]},
    )
    response = client.get("/api/admin/status")
    assert response.status_code == 403
    assert response.json()["error"]["code"] == "ACCESS_DENIED"


def test_request_id_is_returned_without_sensitive_details(client: TestClient) -> None:
    response = client.get("/api/auth/me", headers={"X-Request-ID": "test-request-123"})
    assert response.headers["X-Request-ID"] == "test-request-123"
    body = response.json()
    assert body["error"]["requestId"] == "test-request-123"
    assert "secret" not in response.text.lower()
