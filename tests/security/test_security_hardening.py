import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError

from apps.api.app.config import Settings
from domain.assessment.engine import Condition
from infrastructure.observability.metrics import MetricsRegistry, normalized_endpoint


def test_production_rejects_development_security_configuration() -> None:
    with pytest.raises(ValidationError):
        Settings(app_env="production", cookie_secure=False)
    with pytest.raises(ValidationError):
        Settings(
            app_env="production",
            cookie_secure=True,
            session_secret="development-placeholder-secret-value",
        )
    settings = Settings(
        app_env="production",
        cookie_secure=True,
        session_secret="a-secure-production-secret-with-more-than-32-characters",
        object_storage_provider="S3",
        s3_bucket="private-claim-documents",
        malware_scanner_provider="CLAMAV",
        ocr_provider="HTTP",
        ocr_api_endpoint="https://ocr.example.test/v1/extract",
        ocr_api_key="test-ocr-secret",
        ai_provider="HTTP",
        ai_api_endpoint="https://ai.example.test/v1/extract",
        ai_api_key="test-ai-secret",
        distributed_rate_limit_enabled=True,
    )
    assert settings.object_storage_provider == "S3"


def test_rule_condition_rejects_resource_exhaustion_values() -> None:
    with pytest.raises(ValidationError):
        Condition(path="facts.CODE", operator="IN", value=list(range(101)))
    with pytest.raises(ValidationError):
        Condition(path="facts.CODE", operator="EQ", value="x" * 1001)


def test_metrics_remove_object_identifiers_from_labels() -> None:
    path = "/api/claims/0e3fa73c-9f45-4c29-bf44-0f188c57bf88/result"
    assert normalized_endpoint(path) == "/api/claims/{id}/result"
    registry = MetricsRegistry()
    registry.observe_request(path, 200, 12.5)
    rendered = registry.render()
    assert "0e3fa73c" not in rendered
    assert 'endpoint="/api/claims/{id}/result"' in rendered


def test_api_security_headers_origin_and_body_limit(client: TestClient) -> None:
    health = client.get("/health/live", headers={"X-Request-ID": "x" * 101})
    assert health.status_code == 200
    assert health.headers["x-content-type-options"] == "nosniff"
    assert health.headers["cache-control"] == "no-store"
    assert health.headers["x-request-id"] != "not valid 한글"

    denied = client.post(
        "/api/auth/login",
        headers={"Origin": "https://attacker.invalid"},
        json={"email": "nobody@example.com", "password": "invalid"},
    )
    assert denied.status_code == 403
    assert denied.json()["error"]["code"] == "CSRF_ORIGIN_DENIED"

    oversized = client.post(
        "/api/auth/login",
        content=b"x" * (1024 * 1024 + 1),
        headers={"Content-Type": "application/json"},
    )
    assert oversized.status_code == 413
