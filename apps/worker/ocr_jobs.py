from uuid import UUID

from apps.api.app.config import get_settings
from domain.audit.models import AuditEventType, AuditLog, AuditResult
from domain.document.models import MedicalDocument
from domain.fact.models import OCRResult
from domain.fact.service import mark_ocr_failure, process_ocr
from infrastructure.ai.provider import (
    DevelopmentExtractionProvider,
    HTTPExtractionProvider,
    StructuredExtractionProvider,
)
from infrastructure.database.session import SessionLocal
from infrastructure.ocr.provider import (
    DevelopmentOCRProvider,
    HTTPOCRProvider,
    OCRProvider,
    UnavailableOCRProvider,
)
from infrastructure.storage.object_storage import (
    LocalPrivateStorage,
    ObjectStorage,
    S3CompatibleObjectStorage,
)
from shared.errors import DomainError


def process_ocr_job(ocr_result_id: str) -> None:
    settings = get_settings()
    ocr: OCRProvider
    if settings.ocr_provider == "DEVELOPMENT" and settings.app_env != "production":
        ocr = DevelopmentOCRProvider()
    elif settings.ocr_provider == "HTTP":
        ocr = HTTPOCRProvider(
            settings.ocr_api_endpoint, settings.ocr_api_key, settings.ocr_timeout_seconds
        )
    else:
        ocr = UnavailableOCRProvider()
    extractor: StructuredExtractionProvider
    if settings.ai_provider == "DEVELOPMENT" and settings.app_env != "production":
        extractor = DevelopmentExtractionProvider()
    elif settings.ai_provider == "HTTP":
        extractor = HTTPExtractionProvider(
            settings.ai_api_endpoint, settings.ai_api_key, settings.ocr_timeout_seconds
        )
    else:
        raise DomainError("AI_PROVIDER_ERROR", "AI provider is not configured", 503)
    storage: ObjectStorage
    if settings.object_storage_provider == "LOCAL_PRIVATE":
        storage = LocalPrivateStorage(settings.local_object_storage_root)
    elif settings.object_storage_provider == "S3":
        storage = S3CompatibleObjectStorage(
            settings.s3_bucket,
            settings.s3_region,
            settings.s3_endpoint_url,
            settings.s3_access_key_id,
            settings.s3_secret_access_key,
        )
    else:
        raise DomainError("STORAGE_READ_FAILED", "Object storage is not configured", 503)
    with SessionLocal() as db:
        result = db.get(OCRResult, UUID(ocr_result_id))
        if result is None:
            return
        document = db.get(MedicalDocument, result.document_id)
        try:
            facts = process_ocr(db, result, storage, ocr, extractor)
            for event in (AuditEventType.OCR_COMPLETE, AuditEventType.AI_EXTRACTION_COMPLETE):
                db.add(
                    AuditLog(
                        actor_user_id=None,
                        event_type=event,
                        result=AuditResult.SUCCESS,
                        object_type="OCRResult",
                        object_id=str(result.ocr_result_id),
                        claim_id=document.claim_id if document else None,
                        request_id=f"worker:{result.ocr_result_id}",
                        source_ip=None,
                        before_value=None,
                        after_value={"fact_count": len(facts)},
                    )
                )
            db.commit()
        except DomainError as exc:
            if document:
                mark_ocr_failure(result, document, exc.code)
                db.add(
                    AuditLog(
                        actor_user_id=None,
                        event_type=AuditEventType.OCR_FAILED,
                        result=AuditResult.FAILURE,
                        object_type="OCRResult",
                        object_id=str(result.ocr_result_id),
                        claim_id=document.claim_id,
                        request_id=f"worker:{result.ocr_result_id}",
                        source_ip=None,
                        before_value=None,
                        after_value={"error_code": exc.code},
                    )
                )
                db.commit()
            raise
