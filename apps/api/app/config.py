from functools import lru_cache

from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    app_env: str = "development"
    database_url: str = "sqlite:///./claimlens-dev.db"
    redis_url: str = "redis://localhost:6379/0"
    session_secret: str = "development-only-secret-change-before-production"
    session_cookie_name: str = "claimlens_session"
    session_ttl_seconds: int = 28_800
    cookie_secure: bool = False
    cors_origins: str = "http://localhost:3000"
    log_level: str = "INFO"

    @field_validator("session_secret")
    @classmethod
    def validate_secret(cls, value: str) -> str:
        if len(value) < 32:
            raise ValueError("SESSION_SECRET must contain at least 32 characters")
        return value

    @property
    def cors_origin_list(self) -> list[str]:
        return [origin.strip() for origin in self.cors_origins.split(",") if origin.strip()]


@lru_cache
def get_settings() -> Settings:
    return Settings()
