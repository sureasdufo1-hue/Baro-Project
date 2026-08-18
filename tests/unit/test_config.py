import pytest

from apps.api.app.config import Settings


def test_cors_origins_are_parsed_from_comma_separated_env(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("CORS_ORIGINS", "https://web.example,https://admin.example")
    settings = Settings()
    assert settings.cors_origin_list == ["https://web.example", "https://admin.example"]
