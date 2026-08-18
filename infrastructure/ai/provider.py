import re
from decimal import Decimal
from typing import Protocol

import httpx
from pydantic import BaseModel, ConfigDict, Field

from domain.fact.models import FactType
from shared.errors import DomainError


class StructuredFact(BaseModel):
    model_config = ConfigDict(extra="forbid")
    fact_type: FactType
    value: str = Field(min_length=1, max_length=500)
    confidence: Decimal = Field(ge=0, le=1)
    page: int | None = Field(default=None, ge=1)
    source_text: str | None = Field(default=None, max_length=500)
    source_bbox: dict[str, float] | None = None


class StructuredExtraction(BaseModel):
    model_config = ConfigDict(extra="forbid")
    facts: list[StructuredFact] = Field(max_length=100)


class StructuredExtractionProvider(Protocol):
    provider_name: str
    model_name: str
    model_version: str
    prompt_version: str

    def extract_facts(self, untrusted_ocr_text: str) -> StructuredExtraction: ...


class DevelopmentExtractionProvider:
    """Parses explicit FACT fixture lines only; arbitrary document instructions remain data."""

    provider_name = "DEVELOPMENT"
    model_name = "explicit-fact-fixture"
    model_version = "1"
    prompt_version = "medical-fact-extraction:v1"
    pattern = re.compile(r"^FACT:([A-Z_]+)=([^|\r\n]+)\|([01](?:\.\d+)?)$", re.MULTILINE)

    def extract_facts(self, untrusted_ocr_text: str) -> StructuredExtraction:
        facts = []
        for fact_type, value, confidence in self.pattern.findall(untrusted_ocr_text):
            facts.append(
                StructuredFact(
                    fact_type=FactType(fact_type),
                    value=value.strip(),
                    confidence=Decimal(confidence),
                    source_text=value.strip(),
                )
            )
        return StructuredExtraction(facts=facts)


class HTTPExtractionProvider:
    provider_name = "HTTP"
    model_name = "configured-provider"
    model_version = "configured"
    prompt_version = "medical-fact-extraction:v1"

    def __init__(self, endpoint: str, api_key: str, timeout_seconds: int) -> None:
        self.endpoint = endpoint
        self.api_key = api_key
        self.timeout_seconds = timeout_seconds

    def extract_facts(self, untrusted_ocr_text: str) -> StructuredExtraction:
        try:
            response = httpx.post(
                self.endpoint,
                headers={"Authorization": f"Bearer {self.api_key}"},
                json={
                    "schema": "medical-fact-extraction:v1",
                    "untrusted_ocr_text": untrusted_ocr_text,
                },
                timeout=self.timeout_seconds,
            )
            response.raise_for_status()
            return StructuredExtraction.model_validate(response.json())
        except (httpx.HTTPError, ValueError) as exc:
            raise DomainError(
                "AI_PROVIDER_ERROR", "AI provider returned invalid output", 503
            ) from exc
