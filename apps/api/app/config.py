from functools import lru_cache
from pathlib import Path

from pydantic import field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    app_env: str = "development"
    database_url: str = "sqlite:///./claimlens-dev.db"
    policy_database_url: str = "sqlite:///./dbins_poc/runtime/dbins_policy.sqlite3"
    redis_url: str = "redis://localhost:6379/0"
    session_secret: str = "development-only-secret-change-before-production"
    session_cookie_name: str = "claimlens_session"
    session_ttl_seconds: int = 28_800
    cookie_secure: bool = False
    cors_origins: str = "http://localhost:3000,http://localhost:3001"
    log_level: str = "INFO"
    object_storage_provider: str = "LOCAL_PRIVATE"
    local_object_storage_root: Path = Path(".storage/private")
    s3_bucket: str = ""
    s3_region: str = "ap-northeast-2"
    s3_endpoint_url: str | None = None
    s3_access_key_id: str | None = None
    s3_secret_access_key: str | None = None
    s3_server_side_encryption: str | None = "AES256"
    max_document_file_size_mb: int = 15
    max_documents_per_claim: int = 20
    max_total_document_size_per_claim_mb: int = 100
    signed_url_expiration_seconds: int = 300
    malware_scanner_provider: str = "DEVELOPMENT"
    clamav_host: str = "localhost"
    clamav_port: int = 3310
    clamav_timeout_seconds: int = 10
    ocr_provider: str = "DEVELOPMENT"
    ocr_api_endpoint: str = ""
    ocr_api_key: str = ""
    ai_provider: str = "DEVELOPMENT"
    ai_api_endpoint: str = ""
    ai_api_key: str = ""
    ocr_timeout_seconds: int = 60
    ocr_max_attempts: int = 3
    fact_low_confidence_threshold: float = 0.7
    ocr_worker_concurrency: int = 2
    ai_worker_concurrency: int = 2
    max_json_body_size_kb: int = 1024
    auth_rate_limit_per_minute: int = 120
    upload_rate_limit_per_minute: int = 30
    analysis_rate_limit_per_minute: int = 60
    calculation_rate_limit_per_minute: int = 60
    review_rate_limit_per_minute: int = 120
    security_headers_enabled: bool = True
    distributed_rate_limit_enabled: bool = False

    @field_validator("session_secret")
    @classmethod
    def validate_secret(cls, value: str) -> str:
        if len(value) < 32:
            raise ValueError("SESSION_SECRET must contain at least 32 characters")
        return value

    @model_validator(mode="after")
    def production_safety(self) -> "Settings":
        if self.app_env == "production":
            if not self.cookie_secure:
                raise ValueError("COOKIE_SECURE must be true in production")
            if (
                "development" in self.session_secret.lower()
                or "change" in self.session_secret.lower()
            ):
                raise ValueError("Production SESSION_SECRET must not use a development placeholder")
            if self.object_storage_provider == "LOCAL_PRIVATE":
                raise ValueError("Production object storage must use a managed private provider")
            if self.malware_scanner_provider == "DEVELOPMENT":
                raise ValueError("Production malware scanner must be configured")
            if self.ocr_provider == "DEVELOPMENT" or self.ai_provider == "DEVELOPMENT":
                raise ValueError("Production OCR/AI providers must be configured")
            if self.object_storage_provider != "S3" or not self.s3_bucket:
                raise ValueError("Production S3 object storage is not fully configured")
            if self.malware_scanner_provider != "CLAMAV":
                raise ValueError("Production ClamAV scanner must be configured")
            if self.ocr_provider != "HTTP" or not self.ocr_api_endpoint or not self.ocr_api_key:
                raise ValueError("Production OCR HTTP adapter is not fully configured")
            if self.ai_provider != "HTTP" or not self.ai_api_endpoint or not self.ai_api_key:
                raise ValueError("Production AI HTTP adapter is not fully configured")
            if not self.distributed_rate_limit_enabled:
                raise ValueError("Distributed rate limiting must be enabled in production")
        return self

    @property
    def cors_origin_list(self) -> list[str]:
        return [origin.strip() for origin in self.cors_origins.split(",") if origin.strip()]


@lru_cache
def get_settings() -> Settings:
    return Settings()
