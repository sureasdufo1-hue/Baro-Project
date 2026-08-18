from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, File, Form, Query, Request, Response, UploadFile
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.orm import Session

from apps.api.app.audit import record_audit
from apps.api.app.config import Settings, get_settings
from apps.api.app.dependencies import (
    get_malware_scanner,
    get_object_storage,
    require_authenticated_user,
)
from domain.audit.models import AuditEventType, AuditResult
from domain.document.models import DocumentType, MedicalDocument
from domain.document.service import (
    create_document,
    delete_document,
    document_view,
    list_documents,
    owned_document,
)
from domain.review.models import AdditionalDocumentRequest, DocumentRequestStatus, Review
from domain.user.models import User, UserRole
from infrastructure.database.session import get_db
from infrastructure.security.malware import MalwareScanner
from infrastructure.storage.object_storage import ObjectStorage
from shared.errors import DomainError

claim_router = APIRouter(prefix="/api/claims", tags=["documents"])
document_router = APIRouter(prefix="/api/documents", tags=["documents"])


class DocumentTypePatch(BaseModel):
    document_type: DocumentType


def authorized_document(db: Session, document_id: UUID, user: User) -> MedicalDocument:
    if user.role is not UserRole.ADJUSTER:
        return owned_document(db, document_id, user.user_id)
    document = db.get(MedicalDocument, document_id)
    allowed = document and db.scalar(
        select(Review).where(
            Review.claim_id == document.claim_id,
            Review.reviewer_user_id == user.user_id,
        )
    )
    if document is None or allowed is None:
        raise DomainError("DOCUMENT_ACCESS_DENIED", "Document access is not assigned", 403)
    return document


def audit_document(
    db: Session,
    request: Request,
    user: User,
    event: AuditEventType,
    document: MedicalDocument,
    after: dict[str, Any] | None = None,
    before: dict[str, Any] | None = None,
) -> None:
    record_audit(
        db,
        event_type=event,
        result=AuditResult.SUCCESS,
        actor_user_id=user.user_id,
        object_type="MedicalDocument",
        object_id=str(document.document_id),
        claim_id=document.claim_id,
        request_id=request.state.request_id,
        source_ip=request.client.host if request.client else None,
        before_value=before,
        after_value=after,
    )


@claim_router.get("/{claim_id}/documents", response_model=None)
def get_documents(
    claim_id: UUID,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> list[dict[str, Any]]:
    return [document_view(item) for item in list_documents(db, claim_id, user.user_id)]


@claim_router.post("/{claim_id}/documents", status_code=201, response_model=None)
async def upload_document(
    claim_id: UUID,
    request: Request,
    document_type: DocumentType = Form(..., alias="documentType"),
    additional_document_request_id: UUID | None = Form(
        default=None, alias="additionalDocumentRequestId"
    ),
    file: UploadFile = File(...),
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
    settings: Settings = Depends(get_settings),
    storage: ObjectStorage = Depends(get_object_storage),
    scanner: MalwareScanner = Depends(get_malware_scanner),
) -> dict[str, Any]:
    additional_request = None
    if additional_document_request_id is not None:
        additional_request = db.get(AdditionalDocumentRequest, additional_document_request_id)
        if (
            additional_request is None
            or additional_request.claim_id != claim_id
            or additional_request.request_status is not DocumentRequestStatus.REQUESTED
        ):
            raise DomainError(
                "ADDITIONAL_DOCUMENT_REQUEST_INVALID",
                "Additional document request is not open for this claim",
                409,
            )
    maximum = settings.max_document_file_size_mb * 1024 * 1024
    content = await file.read(maximum + 1)
    document = create_document(
        db,
        storage,
        scanner,
        user.user_id,
        claim_id,
        document_type,
        file.filename,
        file.content_type,
        content,
        maximum,
        settings.max_documents_per_claim,
        settings.max_total_document_size_per_claim_mb * 1024 * 1024,
    )
    if additional_request is not None:
        document.additional_document_request_id = additional_request.request_id
        document.submission_round = additional_request.submission_round
        additional_request.request_status = DocumentRequestStatus.SUBMITTED
    audit_document(db, request, user, AuditEventType.DOCUMENT_SCAN_STARTED, document)
    audit_document(
        db,
        request,
        user,
        AuditEventType.DOCUMENT_SCAN_COMPLETED,
        document,
        after={"malware_scan_status": document.malware_scan_status.value},
    )
    audit_document(
        db,
        request,
        user,
        AuditEventType.DOCUMENT_UPLOAD,
        document,
        after={
            "document_type": document.document_type.value,
            "mime_type": document.mime_type,
            "file_size": document.file_size,
            "file_hash": document.file_hash,
            "additional_document_request_id": str(additional_document_request_id)
            if additional_document_request_id
            else None,
        },
    )
    db.commit()
    db.refresh(document)
    return document_view(document)


@document_router.get("/{document_id}", response_model=None)
def get_document(
    document_id: UUID,
    request: Request,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> dict[str, Any]:
    document = authorized_document(db, document_id, user)
    audit_document(db, request, user, AuditEventType.DOCUMENT_VIEW, document)
    db.commit()
    return document_view(document)


@document_router.patch("/{document_id}", response_model=None)
def patch_document(
    document_id: UUID,
    data: DocumentTypePatch,
    request: Request,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
) -> dict[str, Any]:
    document = owned_document(db, document_id, user.user_id)
    before = {"document_type": document.document_type.value}
    document.document_type = data.document_type
    audit_document(
        db,
        request,
        user,
        AuditEventType.DOCUMENT_TYPE_MODIFY,
        document,
        before=before,
        after={"document_type": data.document_type.value},
    )
    db.commit()
    db.refresh(document)
    return document_view(document)


@document_router.get("/{document_id}/content", response_model=None)
def get_document_content(
    document_id: UUID,
    request: Request,
    download: bool = Query(False),
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
    storage: ObjectStorage = Depends(get_object_storage),
) -> Response:
    document = authorized_document(db, document_id, user)
    content = storage.get_object(document.storage_key)
    event = AuditEventType.DOCUMENT_DOWNLOAD if download else AuditEventType.DOCUMENT_VIEW
    audit_document(db, request, user, event, document)
    db.commit()
    return Response(
        content=content,
        media_type=document.mime_type,
        headers={
            "Content-Disposition": f"{'attachment' if download else 'inline'}; filename=document",
            "X-Content-Type-Options": "nosniff",
            "Content-Security-Policy": "sandbox; default-src 'none'",
            "Cache-Control": "private, no-store",
        },
    )


@document_router.delete("/{document_id}", status_code=204)
def remove_document(
    document_id: UUID,
    request: Request,
    user: User = Depends(require_authenticated_user),
    db: Session = Depends(get_db),
    storage: ObjectStorage = Depends(get_object_storage),
) -> Response:
    document = owned_document(db, document_id, user.user_id)
    delete_document(document, storage)
    audit_document(db, request, user, AuditEventType.DOCUMENT_DELETE, document)
    db.commit()
    return Response(status_code=204)
