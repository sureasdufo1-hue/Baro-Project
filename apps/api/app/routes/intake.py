import json
from datetime import UTC, date, datetime
from decimal import Decimal
from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, File, Form, Request, UploadFile
from pydantic import BaseModel, Field, StrictInt
from sqlalchemy import select
from sqlalchemy.orm import Session

from apps.api.app.audit import record_audit
from apps.api.app.config import Settings, get_settings
from apps.api.app.dependencies import (
    get_extraction_provider,
    get_malware_scanner,
    get_object_storage,
    get_ocr_provider,
    get_ocr_queue,
    require_role,
)
from domain.assessment.models import EligibilityResult
from domain.assessment.service import create_assessments
from domain.audit.models import AuditEventType, AuditResult
from domain.calculation.service import calculate_assessment
from domain.claim.models import ClaimStatus, ClaimType
from domain.claim.service import (
    ClaimStateMachine,
    create_claim,
    submit_accident_information,
)
from domain.contract.models import (
    Gender,
    InsuranceContract,
    Insured,
    RegistrationMethod,
    RelationshipType,
)
from domain.contract.service import create_contract, create_insured, owned_contract
from domain.document.models import DocumentType, MedicalDocument
from domain.document.service import create_document
from domain.evidence.service import build_for_calculation
from domain.fact.models import ExtractedFact, FactType, VerificationStatus, VerifiedFact
from domain.fact.service import confirm_fact, normalize_value, process_ocr, queue_ocr
from domain.review.models import Review, ReviewStatus, ReviewType
from domain.review.service import accept_review, assign_review, create_review
from domain.user.models import User, UserRole
from infrastructure.ai.provider import StructuredExtractionProvider
from infrastructure.database.session import get_db
from infrastructure.ocr.provider import OCRProvider
from infrastructure.queue.ocr import OCRQueue
from infrastructure.security.malware import MalwareScanner
from infrastructure.storage.object_storage import ObjectStorage
from shared.errors import DomainError

router = APIRouter(prefix="/api/intake", tags=["intake"])


class InsuredIntake(BaseModel):
    insured_id: UUID | None = None
    name: str = Field(default="", max_length=100)
    birth_date: date | None = None
    gender: Gender = Gender.UNKNOWN
    relationship_type: RelationshipType = RelationshipType.SELF


class CoverageIntake(BaseModel):
    coverage_id: UUID
    coverage_name_snapshot: str = Field(min_length=1, max_length=250)
    insured_amount: StrictInt = Field(ge=0)
    coverage_start_date: date | None = None
    coverage_end_date: date | None = None


class ContractIntake(BaseModel):
    contract_id: UUID | None = None
    product_version_id: UUID | None = None
    policy_version_id: UUID | None = None
    policy_number: str | None = Field(default=None, max_length=150)
    contract_date: date | None = None
    coverage_start_date: date | None = None
    coverage_end_date: date | None = None
    coverages: list[CoverageIntake] = Field(default_factory=list)


class IncidentIntake(BaseModel):
    claim_type: ClaimType = ClaimType.DISEASE
    title: str | None = Field(default=None, max_length=200)
    accident_date: date | None = None
    diagnosis_date: date | None = None
    onset_date: date | None = None
    description: str | None = Field(default=None, max_length=4000)
    location: str | None = Field(default=None, max_length=300)


class DirectFactIntake(BaseModel):
    fact_type: FactType
    value: str = Field(min_length=1, max_length=500)


class DocumentMetadataIntake(BaseModel):
    filename: str
    document_type: DocumentType = DocumentType.DIAGNOSIS_CERTIFICATE


class IntakeOptions(BaseModel):
    auto_analyze: bool = True
    auto_confirm_facts: bool = True
    auto_assess: bool = True
    create_review: bool = True
    assigned_adjuster_user_id: UUID | None = None
    review_reason: str = "원스톱 사건 접수에 따른 손해사정 심사 및 보고서 작성"


class IntakePayload(BaseModel):
    insured: InsuredIntake
    contract: ContractIntake
    incident: IncidentIntake
    direct_facts: list[DirectFactIntake] = Field(default_factory=list)
    documents_metadata: list[DocumentMetadataIntake] = Field(default_factory=list)
    options: IntakeOptions = Field(default_factory=IntakeOptions)


async def execute_intake(
    db: Session,
    user: User,
    request: Request,
    payload: IntakePayload,
    files: list[UploadFile],
    settings: Settings,
    storage: ObjectStorage,
    scanner: MalwareScanner,
    ocr_provider: OCRProvider,
    extraction_provider: StructuredExtractionProvider,
    queue: OCRQueue,
) -> dict[str, Any]:
    # 1. Insured
    insured: Insured
    if payload.insured.insured_id is not None:
        existing_ins = db.get(Insured, payload.insured.insured_id)
        if existing_ins is None or existing_ins.owner_user_id != user.user_id:
            raise DomainError("INSURED_NOT_FOUND", "Insured was not found", 404)
        insured = existing_ins
    else:
        name = (payload.insured.name or "피보험자").strip()
        rel = payload.insured.relationship_type
        if rel is RelationshipType.SELF:
            existing_self = db.scalar(
                select(Insured).where(
                    Insured.owner_user_id == user.user_id,
                    Insured.relationship_type == RelationshipType.SELF,
                )
            )
            if existing_self and existing_self.name == name:
                insured = existing_self
            elif existing_self:
                rel = RelationshipType.OTHER
                insured = create_insured(
                    db,
                    user.user_id,
                    {
                        "name": name,
                        "birth_date": payload.insured.birth_date,
                        "gender": payload.insured.gender,
                        "relationship_type": rel,
                    },
                )
            else:
                insured = create_insured(
                    db,
                    user.user_id,
                    {
                        "name": name,
                        "birth_date": payload.insured.birth_date,
                        "gender": payload.insured.gender,
                        "relationship_type": rel,
                    },
                )
        else:
            insured = create_insured(
                db,
                user.user_id,
                {
                    "name": name,
                    "birth_date": payload.insured.birth_date,
                    "gender": payload.insured.gender,
                    "relationship_type": rel,
                },
            )
        record_audit(
            db,
            event_type=AuditEventType.INSURED_CREATE,
            result=AuditResult.SUCCESS,
            actor_user_id=user.user_id,
            object_type="Insured",
            object_id=str(insured.insured_id),
            request_id=request.state.request_id,
            source_ip=request.client.host if request.client else None,
        )

    # 2. Contract
    contract: InsuranceContract
    if payload.contract.contract_id is not None:
        contract = owned_contract(db, payload.contract.contract_id, user.user_id)
    else:
        if payload.contract.product_version_id is None:
            raise DomainError("PRODUCT_VERSION_REQUIRED", "Product version is required", 422)
        raw_contract = {
            "insured_id": insured.insured_id,
            "product_version_id": payload.contract.product_version_id,
            "policy_version_id": payload.contract.policy_version_id,
            "policy_number": payload.contract.policy_number,
            "contract_date": payload.contract.contract_date,
            "coverage_start_date": payload.contract.coverage_start_date,
            "coverage_end_date": payload.contract.coverage_end_date,
            "registration_method": RegistrationMethod.MANUAL,
        }
        coverage_data = [c.model_dump() for c in payload.contract.coverages]
        contract = create_contract(db, user.user_id, raw_contract, coverage_data)
        record_audit(
            db,
            event_type=AuditEventType.CONTRACT_CREATE,
            result=AuditResult.SUCCESS,
            actor_user_id=user.user_id,
            object_type="InsuranceContract",
            object_id=str(contract.contract_id),
            request_id=request.state.request_id,
            source_ip=request.client.host if request.client else None,
        )

    # 3. Claim & Accident
    accident_dict = {
        "accident_date": payload.incident.accident_date,
        "diagnosis_date": payload.incident.diagnosis_date,
        "onset_date": payload.incident.onset_date,
        "description": payload.incident.description,
        "location": payload.incident.location,
    }
    claim = create_claim(
        db,
        user.user_id,
        contract.contract_id,
        payload.incident.claim_type,
        payload.incident.title,
        accident_dict,
    )
    submit_accident_information(claim)
    record_audit(
        db,
        event_type=AuditEventType.CLAIM_CREATE,
        result=AuditResult.SUCCESS,
        actor_user_id=user.user_id,
        object_type="Claim",
        object_id=str(claim.claim_id),
        claim_id=claim.claim_id,
        request_id=request.state.request_id,
        source_ip=request.client.host if request.client else None,
    )

    # 4. Upload Documents
    uploaded_docs: list[MedicalDocument] = []
    meta_map = {m.filename: m.document_type for m in payload.documents_metadata}
    max_size = settings.max_document_file_size_mb * 1024 * 1024
    for idx, f in enumerate(files):
        content = await f.read(max_size + 1)
        dtype = meta_map.get(
            f.filename or "",
            payload.documents_metadata[idx].document_type
            if idx < len(payload.documents_metadata)
            else DocumentType.DIAGNOSIS_CERTIFICATE,
        )
        doc = create_document(
            db,
            storage,
            scanner,
            user.user_id,
            claim.claim_id,
            dtype,
            f.filename,
            f.content_type,
            content,
            max_size,
            settings.max_documents_per_claim,
            settings.max_total_document_size_per_claim_mb * 1024 * 1024,
        )
        uploaded_docs.append(doc)
        record_audit(
            db,
            event_type=AuditEventType.DOCUMENT_UPLOAD,
            result=AuditResult.SUCCESS,
            actor_user_id=user.user_id,
            object_type="MedicalDocument",
            object_id=str(doc.document_id),
            claim_id=claim.claim_id,
            request_id=request.state.request_id,
            source_ip=request.client.host if request.client else None,
        )

    # 5. Direct Facts provenance document if no documents were uploaded
    if payload.direct_facts and not uploaded_docs:
        fact_lines = [f"FACT:{df.fact_type.value}={df.value}|1.0" for df in payload.direct_facts]
        declaration_content = (
            b"%PDF-1.4\n[ADJUSTER INTAKE DECLARATION]\n"
            + "\n".join(fact_lines).encode("utf-8")
            + b"\n%%EOF"
        )
        declaration_doc = create_document(
            db,
            storage,
            scanner,
            user.user_id,
            claim.claim_id,
            DocumentType.OTHER,
            "intake_declaration.pdf",
            "application/pdf",
            declaration_content,
            max_size,
            settings.max_documents_per_claim,
            settings.max_total_document_size_per_claim_mb * 1024 * 1024,
        )
        uploaded_docs.append(declaration_doc)
        record_audit(
            db,
            event_type=AuditEventType.DOCUMENT_UPLOAD,
            result=AuditResult.SUCCESS,
            actor_user_id=user.user_id,
            object_type="MedicalDocument",
            object_id=str(declaration_doc.document_id),
            claim_id=claim.claim_id,
            request_id=request.state.request_id,
            source_ip=request.client.host if request.client else None,
        )

    # 6. OCR and Extraction
    if payload.options.auto_analyze and uploaded_docs and files:
        ClaimStateMachine.transition(claim, ClaimStatus.DOCUMENT_PROCESSING)
        for doc in uploaded_docs:
            res = queue_ocr(db, doc, ocr_provider)
            extracted = process_ocr(db, res, storage, ocr_provider, extraction_provider)
            if payload.options.auto_confirm_facts:
                for ef in extracted:
                    existing = db.scalar(
                        select(VerifiedFact).where(
                            VerifiedFact.extracted_fact_id == ef.extracted_fact_id
                        )
                    )
                    if existing is None:
                        vf = confirm_fact(db, ef, user.user_id)
                        vf.verification_status = VerificationStatus.EXPERT_CONFIRMED
    elif payload.direct_facts and uploaded_docs:
        # Create provenance chain for direct facts
        ClaimStateMachine.transition(claim, ClaimStatus.DOCUMENT_PROCESSING)
        source_doc = uploaded_docs[0]
        ocr_res = queue_ocr(db, source_doc, ocr_provider)
        for df in payload.direct_facts:
            ef = ExtractedFact(
                claim_id=claim.claim_id,
                document_id=source_doc.document_id,
                ocr_result_id=ocr_res.ocr_result_id,
                fact_type=df.fact_type,
                fact_value=df.value,
                normalized_value=normalize_value(df.fact_type, df.value),
                confidence=Decimal("1.0000"),
                page_number=1,
                source_text=df.value,
                extractor_provider="ADJUSTER_MANUAL_INTAKE",
                extractor_model="intake_form:v1",
                prompt_version="intake:v1",
            )
            db.add(ef)
            db.flush()
            vf = VerifiedFact(
                claim_id=claim.claim_id,
                extracted_fact_id=ef.extracted_fact_id,
                fact_type=df.fact_type,
                verified_value=ef.normalized_value,
                verification_status=VerificationStatus.EXPERT_CONFIRMED,
                verified_by=user.user_id,
                verified_at=datetime.now(UTC),
                modification_reason="손해사정사 직접 접수 입력",
                source_document_id=source_doc.document_id,
                source_page=1,
            )
            db.add(vf)
        ClaimStateMachine.transition(claim, ClaimStatus.USER_VERIFICATION)

    # 7. Assessment & Calculation
    assessments = []
    calculations = []
    if payload.options.auto_assess and claim.status is ClaimStatus.USER_VERIFICATION:
        if len(contract.coverages) > 0:
            assessments = create_assessments(db, claim.claim_id, user.user_id)
            for ass in assessments:
                if ass.eligibility_result in (
                    EligibilityResult.PAYABLE,
                    EligibilityResult.NOT_PAYABLE,
                ):
                    try:
                        calc = calculate_assessment(db, ass.assessment_id, user.user_id)
                        build_for_calculation(db, calc.calculation_id, user.user_id)
                        calculations.append(calc)
                    except Exception as exc:
                        import logging

                        logger = logging.getLogger("claimlens.intake")
                        logger.exception("Intake calculation error: %s", exc)

    # 8. Review Creation & Assignment
    review: Review | None = None
    if payload.options.create_review:
        if claim.status is ClaimStatus.ASSESSING:
            ClaimStateMachine.transition(claim, ClaimStatus.MANUAL_REVIEW)
        elif claim.status is ClaimStatus.USER_VERIFICATION and not assessments:
            ClaimStateMachine.transition(claim, ClaimStatus.MANUAL_REVIEW)

        if claim.status is ClaimStatus.MANUAL_REVIEW:
            review = create_review(
                db,
                claim,
                ReviewType.GENERAL_CLAIM_REVIEW,
                payload.options.review_reason,
            )
            reviewer: User | None = None
            if user.role is UserRole.ADJUSTER:
                reviewer = user
            elif payload.options.assigned_adjuster_user_id:
                cand = db.get(User, payload.options.assigned_adjuster_user_id)
                if cand and cand.role is UserRole.ADJUSTER:
                    reviewer = cand
            elif user.role is UserRole.SYSTEM_ADMIN:
                reviewer = db.scalar(select(User).where(User.role == UserRole.ADJUSTER))

            if reviewer is not None and review.review_status is ReviewStatus.REQUESTED:
                assign_review(db, review, reviewer, user.user_id)
                if reviewer.user_id == user.user_id:
                    accept_review(db, review)

    db.commit()
    db.refresh(claim)

    total_amount = sum(c.final_amount for c in calculations if c.final_amount is not None)
    redirect_url = f"/reviews/{review.review_id}" if review else f"/claims/{claim.claim_id}"

    return {
        "claim_id": str(claim.claim_id),
        "claim_number": claim.claim_number,
        "contract_id": str(contract.contract_id),
        "insured_id": str(insured.insured_id),
        "claim_status": claim.status.value,
        "documents_count": len(uploaded_docs),
        "assessments_count": len(assessments),
        "calculations_count": len(calculations),
        "total_benefit_amount": total_amount,
        "review_id": str(review.review_id) if review else None,
        "review_status": review.review_status.value if review else None,
        "redirect_url": redirect_url,
    }


@router.post("", status_code=201, response_model=None)
async def post_intake_multipart(
    request: Request,
    payload: str = Form(..., description="JSON string of IntakePayload"),
    files: list[UploadFile] = File(default=[]),
    user: User = Depends(require_role(UserRole.ADJUSTER, UserRole.SYSTEM_ADMIN)),
    db: Session = Depends(get_db),
    settings: Settings = Depends(get_settings),
    storage: ObjectStorage = Depends(get_object_storage),
    scanner: MalwareScanner = Depends(get_malware_scanner),
    ocr_provider: OCRProvider = Depends(get_ocr_provider),
    extraction_provider: StructuredExtractionProvider = Depends(get_extraction_provider),
    queue: OCRQueue = Depends(get_ocr_queue),
) -> dict[str, Any]:
    try:
        data = json.loads(payload)
        parsed = IntakePayload.model_validate(data)
    except Exception as exc:
        raise DomainError("INVALID_INTAKE_PAYLOAD", f"Invalid intake payload: {exc}", 422) from exc

    return await execute_intake(
        db,
        user,
        request,
        parsed,
        files,
        settings,
        storage,
        scanner,
        ocr_provider,
        extraction_provider,
        queue,
    )


@router.post("/json", status_code=201, response_model=None)
async def post_intake_json(
    data: IntakePayload,
    request: Request,
    user: User = Depends(require_role(UserRole.ADJUSTER, UserRole.SYSTEM_ADMIN)),
    db: Session = Depends(get_db),
    settings: Settings = Depends(get_settings),
    storage: ObjectStorage = Depends(get_object_storage),
    scanner: MalwareScanner = Depends(get_malware_scanner),
    ocr_provider: OCRProvider = Depends(get_ocr_provider),
    extraction_provider: StructuredExtractionProvider = Depends(get_extraction_provider),
    queue: OCRQueue = Depends(get_ocr_queue),
) -> dict[str, Any]:
    return await execute_intake(
        db,
        user,
        request,
        data,
        [],
        settings,
        storage,
        scanner,
        ocr_provider,
        extraction_provider,
        queue,
    )
