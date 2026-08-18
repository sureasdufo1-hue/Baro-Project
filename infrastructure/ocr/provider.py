from dataclasses import dataclass
from decimal import Decimal
from typing import Any, Protocol

import httpx

from shared.errors import DomainError


@dataclass(frozen=True)
class CanonicalOCRResult:
    text: str
    confidence: Decimal
    pages: list[dict[str, Any]]


class OCRProvider(Protocol):
    provider_name: str
    model_name: str
    model_version: str

    def extract(self, content: bytes, mime_type: str) -> CanonicalOCRResult: ...


class DevelopmentOCRProvider:
    provider_name = "DEVELOPMENT"
    model_name = "explicit-text-fixture"
    model_version = "1"

    def extract(self, content: bytes, mime_type: str) -> CanonicalOCRResult:
        del mime_type
        text = content.decode("utf-8", errors="ignore")
        if "CLAIMLENS_OCR_FAILURE" in text:
            raise DomainError("OCR_PROVIDER_ERROR", "Development OCR failure", 503)
        return CanonicalOCRResult(text=text[:100_000], confidence=Decimal("0.9900"), pages=[])


class UnavailableOCRProvider:
    provider_name = "UNAVAILABLE"
    model_name = "unconfigured"
    model_version = "0"

    def extract(self, content: bytes, mime_type: str) -> CanonicalOCRResult:
        del content, mime_type
        raise DomainError("OCR_PROVIDER_ERROR", "OCR provider is not configured", 503)


class HTTPOCRProvider:
    provider_name = "HTTP"

    def __init__(self, endpoint: str, api_key: str, timeout_seconds: int) -> None:
        self.endpoint = endpoint
        self.api_key = api_key
        self.timeout_seconds = timeout_seconds
        self.model_name = "configured-provider"
        self.model_version = "configured"

    def extract(self, content: bytes, mime_type: str) -> CanonicalOCRResult:
        try:
            response = httpx.post(
                self.endpoint,
                headers={"Authorization": f"Bearer {self.api_key}"},
                files={"file": ("document", content, mime_type)},
                timeout=self.timeout_seconds,
            )
            response.raise_for_status()
            payload = response.json()
            text = payload["text"]
            confidence = Decimal(str(payload["confidence"]))
            pages = payload.get("pages", [])
            if not isinstance(text, str) or not isinstance(pages, list):
                raise ValueError("invalid OCR response")
            return CanonicalOCRResult(text[:100_000], confidence, pages)
        except (httpx.HTTPError, KeyError, TypeError, ValueError) as exc:
            raise DomainError("OCR_PROVIDER_ERROR", "OCR provider failed", 503) from exc
