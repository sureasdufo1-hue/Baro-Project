from __future__ import annotations

from pathlib import Path

from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session

from apps.api.app.dependencies import (
    get_extraction_provider,
    get_malware_scanner,
    get_object_storage,
    get_ocr_provider,
    get_ocr_queue,
)
from domain.calculation.models import CalculationStatus
from domain.fact.models import OCRResult
from domain.fact.service import process_ocr
from domain.policy.models import (
    Coverage,
    InsuranceCompany,
    InsuranceProduct,
    ProductVersion,
)
from infrastructure.ai.provider import DevelopmentExtractionProvider
from infrastructure.ocr.provider import DevelopmentOCRProvider
from infrastructure.security.malware import ScanResult
from infrastructure.storage.object_storage import LocalPrivateStorage
from scripts.seed_db_insurance_master import seed_db_insurance_master
from tests.integration.test_contracts import register_login
from tests.integration.test_documents import FixedScanner
from tests.integration.test_ocr_fact_flow import CapturingQueue


def test_db_insurance_cancer_claim_full_e2e_flow(
    client: TestClient, db_session: Session, tmp_path: Path
) -> None:
    """Complete E2E lifecycle for DB Insurance (무)프로미라이프 New간편암건강보험2601."""
    # 1. Seed DB Insurance Masters & Rules
    seed_db_insurance_master(db_session)

    company = db_session.execute(
        select(InsuranceCompany).where(InsuranceCompany.company_code == "DB_INSURANCE")
    ).scalar_one()
    product = db_session.execute(
        select(InsuranceProduct).where(
            InsuranceProduct.company_id == company.company_id,
            InsuranceProduct.product_code == "31201",
        )
    ).scalar_one()
    pv = db_session.execute(
        select(ProductVersion).where(ProductVersion.product_id == product.product_id)
    ).scalar_one()
    cancer_cov = db_session.execute(
        select(Coverage).where(Coverage.standard_code == "STD_CANCER_DIAG")
    ).scalar_one()
    sim_cov = db_session.execute(
        select(Coverage).where(Coverage.standard_code == "STD_SIMILAR_CANCER_DIAG")
    ).scalar_one()

    # 2. Register & Login as User
    user_email = "dbins-cancer-user@example.com"
    register_login(client, user_email)

    # Setup storage & mock services
    storage = LocalPrivateStorage(tmp_path / user_email)
    queue = CapturingQueue()
    client.app.dependency_overrides[get_object_storage] = lambda: storage
    client.app.dependency_overrides[get_malware_scanner] = lambda: FixedScanner(ScanResult.CLEAN)
    client.app.dependency_overrides[get_ocr_provider] = DevelopmentOCRProvider
    client.app.dependency_overrides[get_extraction_provider] = DevelopmentExtractionProvider
    client.app.dependency_overrides[get_ocr_queue] = lambda: queue

    # 3. Create Insured Person
    insured_res = client.post("/api/insureds", json={"name": "홍길동", "relationship_type": "SELF"})
    assert insured_res.status_code == 201
    insured_id = insured_res.json()["insured_id"]

    # 4. Create Insurance Contract with DB Insurance Cancer Coverages
    contract_res = client.post(
        "/api/contracts",
        json={
            "insured_id": insured_id,
            "product_version_id": str(pv.product_version_id),
            "policy_number": "DB-31201-20260401-001",
            "coverage_start_date": "2026-04-01",
            "coverage_end_date": "2046-04-01",
            "coverages": [
                {
                    "coverage_id": str(cancer_cov.coverage_id),
                    "coverage_name_snapshot": "일반암진단비(유사암제외)",
                    "insured_amount": 50000000,
                },
                {
                    "coverage_id": str(sim_cov.coverage_id),
                    "coverage_name_snapshot": "유사암진단비",
                    "insured_amount": 10000000,
                },
            ],
        },
    )
    assert contract_res.status_code == 201
    contract_id = contract_res.json()["contract_id"]

    # 5. Create Claim (Disease: 위암 진단 청구)
    claim_res = client.post(
        "/api/claims",
        json={
            "contract_id": contract_id,
            "claim_type": "DISEASE",
            "title": "DB손해보험 위암 진단비 청구",
            "accident": {
                "diagnosis_date": "2026-08-10",
                "onset_date": "2026-08-01",
                "description": "건강검진 위내시경 조직검사 결과 위암(C16) 확진",
            },
        },
    )
    assert claim_res.status_code == 201
    claim_id = claim_res.json()["claim_id"]

    # 6. Submit Accident Info Transition
    trans_res = client.post(
        f"/api/claims/{claim_id}/transitions",
        json={"action": "SUBMIT_ACCIDENT_INFORMATION"},
    )
    assert trans_res.status_code == 200
    assert trans_res.json()["status"] == "DOCUMENT_REQUIRED"

    # 7. Upload Diagnosis Document (PDF)
    doc_content = (
        b"%PDF-1.4\n"
        b"FACT:DIAGNOSIS_NAME=Malignant neoplasm of stomach|0.98\n"
        b"FACT:DIAGNOSIS_CODE=C16|0.99\n"
        b"FACT:DIAGNOSIS_DATE=2026. 8. 10.|0.95\n"
        b"%%EOF"
    )
    upload_res = client.post(
        f"/api/claims/{claim_id}/documents",
        data={"documentType": "DIAGNOSIS_CERTIFICATE"},
        files={"file": ("diagnosis_c16.pdf", doc_content, "application/pdf")},
    )
    assert upload_res.status_code == 201

    # 8. Request Analysis & Transition to Assessment / Calculation
    analysis_req = client.post(f"/api/claims/{claim_id}/analysis")
    assert analysis_req.status_code == 202
    assert analysis_req.json()["claim_status"] == "DOCUMENT_PROCESSING"
    assert len(queue.ids) == 1

    # Process background OCR queue
    ocr_result = db_session.get(OCRResult, queue.ids[0])
    assert ocr_result is not None
    extracted_facts = process_ocr(
        db_session,
        ocr_result,
        storage,
        DevelopmentOCRProvider(),
        DevelopmentExtractionProvider(),
    )
    db_session.commit()
    assert len(extracted_facts) >= 2

    # 9. User Confirms Extracted Facts via API
    facts_res = client.get(f"/api/claims/{claim_id}/facts")
    assert facts_res.status_code == 200
    for f in facts_res.json():
        conf_res = client.post(f"/api/facts/{f['extracted_fact_id']}/confirm")
        assert conf_res.status_code == 200

    # 10. Execute Assessment API
    assess_res = client.post(f"/api/claims/{claim_id}/assess")
    assert assess_res.status_code == 201
    assessments = assess_res.json()
    assert len(assessments) == 2

    # 11. Execute Calculation API for each assessment
    for assess in assessments:
        calc_res = client.post(f"/api/assessments/{assess['assessment_id']}/calculate")
        assert calc_res.status_code in (201, 200)

    # 12. List & Verify Claim Calculations (일반암: 5,000만원 지급 / 유사암: 0원)
    calculations = client.get(f"/api/claims/{claim_id}/calculations").json()
    assert len(calculations) == 2

    cancer_calc = next(c for c in calculations if c["final_amount"] == 50000000)
    assert cancer_calc["final_amount"] == 50000000
    assert cancer_calc["calculation_status"] == CalculationStatus.CALCULATED.value

    sim_calc = next(c for c in calculations if c["final_amount"] == 0)
    assert sim_calc["final_amount"] == 0
    assert sim_calc["calculation_status"] == CalculationStatus.NOT_PAYABLE.value


def test_db_insurance_cardiovascular_claim_full_e2e_flow(
    client: TestClient, db_session: Session, tmp_path: Path
) -> None:
    """Complete E2E lifecycle for DB Insurance (무)프로미라이프 참좋은훼밀리종합보험 (뇌/심장)."""
    seed_db_insurance_master(db_session)

    company = db_session.execute(
        select(InsuranceCompany).where(InsuranceCompany.company_code == "DB_INSURANCE")
    ).scalar_one()
    product = db_session.execute(
        select(InsuranceProduct).where(
            InsuranceProduct.company_id == company.company_id,
            InsuranceProduct.product_code == "31100",
        )
    ).scalar_one()
    pv = db_session.execute(
        select(ProductVersion).where(ProductVersion.product_id == product.product_id)
    ).scalar_one()
    hem_cov = db_session.execute(
        select(Coverage).where(Coverage.standard_code == "STD_CEREBRAL_HEMORRHAGE_DIAG")
    ).scalar_one()
    stroke_cov = db_session.execute(
        select(Coverage).where(Coverage.standard_code == "STD_STROKE_DIAG")
    ).scalar_one()
    mi_cov = db_session.execute(
        select(Coverage).where(Coverage.standard_code == "STD_ACUTE_MYOCARDIAL_INFARCTION_DIAG")
    ).scalar_one()
    isch_cov = db_session.execute(
        select(Coverage).where(Coverage.standard_code == "STD_ISCHEMIC_HEART_DIAG")
    ).scalar_one()

    user_email = "dbins-cardio-user@example.com"
    register_login(client, user_email)

    storage = LocalPrivateStorage(tmp_path / user_email)
    queue = CapturingQueue()
    client.app.dependency_overrides[get_object_storage] = lambda: storage
    client.app.dependency_overrides[get_malware_scanner] = lambda: FixedScanner(ScanResult.CLEAN)
    client.app.dependency_overrides[get_ocr_provider] = DevelopmentOCRProvider
    client.app.dependency_overrides[get_extraction_provider] = DevelopmentExtractionProvider
    client.app.dependency_overrides[get_ocr_queue] = lambda: queue

    insured_res = client.post("/api/insureds", json={"name": "이순신", "relationship_type": "SELF"})
    insured_id = insured_res.json()["insured_id"]

    # Contract with 4 cardio/cerebrovascular coverages
    contract_res = client.post(
        "/api/contracts",
        json={
            "insured_id": insured_id,
            "product_version_id": str(pv.product_version_id),
            "policy_number": "DB-31100-202401-001",
            "coverage_start_date": "2024-01-01",
            "coverage_end_date": "2054-01-01",
            "coverages": [
                {
                    "coverage_id": str(hem_cov.coverage_id),
                    "coverage_name_snapshot": "뇌출혈진단비",
                    "insured_amount": 30000000,
                },
                {
                    "coverage_id": str(stroke_cov.coverage_id),
                    "coverage_name_snapshot": "뇌졸중진단비",
                    "insured_amount": 20000000,
                },
                {
                    "coverage_id": str(mi_cov.coverage_id),
                    "coverage_name_snapshot": "급성심근경색증진단비",
                    "insured_amount": 30000000,
                },
                {
                    "coverage_id": str(isch_cov.coverage_id),
                    "coverage_name_snapshot": "허혈성심장질환진단비",
                    "insured_amount": 10000000,
                },
            ],
        },
    )
    contract_id = contract_res.json()["contract_id"]

    # Claim: 뇌경색증(I63) 진단 확진
    claim_res = client.post(
        "/api/claims",
        json={
            "contract_id": contract_id,
            "claim_type": "DISEASE",
            "title": "DB손해보험 뇌경색 진단비 청구",
            "accident": {
                "diagnosis_date": "2026-08-15",
                "onset_date": "2026-08-14",
                "description": "뇌 MRI 촬영 결과 급성 뇌경색증(I63) 진단",
            },
        },
    )
    claim_id = claim_res.json()["claim_id"]

    client.post(
        f"/api/claims/{claim_id}/transitions",
        json={"action": "SUBMIT_ACCIDENT_INFORMATION"},
    )

    doc_content = (
        b"%PDF-1.4\n"
        b"FACT:DIAGNOSIS_NAME=Cerebral infarction|0.98\n"
        b"FACT:DIAGNOSIS_CODE=I63|0.99\n"
        b"FACT:DIAGNOSIS_DATE=2026. 8. 15.|0.95\n"
        b"%%EOF"
    )
    client.post(
        f"/api/claims/{claim_id}/documents",
        data={"documentType": "DIAGNOSIS_CERTIFICATE"},
        files={"file": ("diagnosis_i63.pdf", doc_content, "application/pdf")},
    )

    client.post(f"/api/claims/{claim_id}/analysis")
    ocr_result = db_session.get(OCRResult, queue.ids[0])
    assert ocr_result is not None
    process_ocr(
        db_session,
        ocr_result,
        storage,
        DevelopmentOCRProvider(),
        DevelopmentExtractionProvider(),
    )
    db_session.commit()

    facts_res = client.get(f"/api/claims/{claim_id}/facts")
    for f in facts_res.json():
        client.post(f"/api/facts/{f['extracted_fact_id']}/confirm")

    # Assess
    assess_res = client.post(f"/api/claims/{claim_id}/assess")
    assert assess_res.status_code == 201
    assessments = assess_res.json()
    assert len(assessments) == 4

    # Calculate
    for assess in assessments:
        calc_res = client.post(f"/api/assessments/{assess['assessment_id']}/calculate")
        assert calc_res.status_code in (201, 200)

    calculations = client.get(f"/api/claims/{claim_id}/calculations").json()
    assert len(calculations) == 4

    stroke_calc = next(c for c in calculations if c["final_amount"] == 20000000)
    assert stroke_calc["final_amount"] == 20000000
    assert stroke_calc["calculation_status"] == CalculationStatus.CALCULATED.value

    hem_calc = next(
        c
        for c in calculations
        if c["final_amount"] == 0 and c["insured_amount_snapshot"] == 30000000
    )
    assert hem_calc["final_amount"] == 0
    assert hem_calc["calculation_status"] == CalculationStatus.NOT_PAYABLE.value


def test_db_insurance_complex_injury_disability_and_indemnity_claim_flow(
    client: TestClient, db_session: Session, tmp_path: Path
) -> None:
    """Complex multi-coverage claim for Injury Disability (15%) + Surgery + Medical Expenses."""
    seed_db_insurance_master(db_session)

    company = db_session.execute(
        select(InsuranceCompany).where(InsuranceCompany.company_code == "DB_INSURANCE")
    ).scalar_one()
    product = db_session.execute(
        select(InsuranceProduct).where(
            InsuranceProduct.company_id == company.company_id,
            InsuranceProduct.product_code == "31100",
        )
    ).scalar_one()
    pv = db_session.execute(
        select(ProductVersion).where(ProductVersion.product_id == product.product_id)
    ).scalar_one()

    inj_dis_cov = db_session.execute(
        select(Coverage).where(Coverage.standard_code == "STD_INJURY_DISABILITY_3_TO_100")
    ).scalar_one()
    inj_surg_cov = db_session.execute(
        select(Coverage).where(Coverage.standard_code == "STD_INJURY_SURGERY")
    ).scalar_one()
    med_ben_cov = db_session.execute(
        select(Coverage).where(Coverage.standard_code == "STD_INDEMNITY_BENEFIT")
    ).scalar_one()
    med_non_cov = db_session.execute(
        select(Coverage).where(Coverage.standard_code == "STD_INDEMNITY_NON_BENEFIT")
    ).scalar_one()

    user_email = "dbins-complex-injury@example.com"
    register_login(client, user_email)

    storage = LocalPrivateStorage(tmp_path / user_email)
    queue = CapturingQueue()
    client.app.dependency_overrides[get_object_storage] = lambda: storage
    client.app.dependency_overrides[get_malware_scanner] = lambda: FixedScanner(ScanResult.CLEAN)
    client.app.dependency_overrides[get_ocr_provider] = DevelopmentOCRProvider
    client.app.dependency_overrides[get_extraction_provider] = DevelopmentExtractionProvider
    client.app.dependency_overrides[get_ocr_queue] = lambda: queue

    insured_res = client.post("/api/insureds", json={"name": "강감찬", "relationship_type": "SELF"})
    insured_id = insured_res.json()["insured_id"]

    # Contract with 4 coverages
    contract_res = client.post(
        "/api/contracts",
        json={
            "insured_id": insured_id,
            "product_version_id": str(pv.product_version_id),
            "policy_number": "DB-31100-2026-COMPLEX-01",
            "coverage_start_date": "2024-01-01",
            "coverage_end_date": "2054-01-01",
            "coverages": [
                {
                    "coverage_id": str(inj_dis_cov.coverage_id),
                    "coverage_name_snapshot": "상해후유장해(3~100%)",
                    "insured_amount": 100000000,
                },
                {
                    "coverage_id": str(inj_surg_cov.coverage_id),
                    "coverage_name_snapshot": "상해수술비",
                    "insured_amount": 2000000,
                },
                {
                    "coverage_id": str(med_ben_cov.coverage_id),
                    "coverage_name_snapshot": "질병/상해 급여 실손의료비",
                    "insured_amount": 50000000,
                },
                {
                    "coverage_id": str(med_non_cov.coverage_id),
                    "coverage_name_snapshot": "질병/상해 비급여 실손의료비",
                    "insured_amount": 50000000,
                },
            ],
        },
    )
    contract_id = contract_res.json()["contract_id"]

    # Claim for INJURY
    claim_res = client.post(
        "/api/claims",
        json={
            "contract_id": contract_id,
            "claim_type": "INJURY",
            "title": "DB손해보험 상해 사고 복합 청구 (수술/장해/실손)",
            "accident": {
                "accident_date": "2026-08-01",
                "location": "서울 강남구 교차로",
                "description": "교통사고로 대퇴골 골절 수술 및 15% 후유장해 진단",
            },
        },
    )
    claim_id = claim_res.json()["claim_id"]

    client.post(
        f"/api/claims/{claim_id}/transitions",
        json={"action": "SUBMIT_ACCIDENT_INFORMATION"},
    )

    doc_content = (
        b"%PDF-1.4\n"
        b"FACT:ACCIDENT_DATE=2026. 8. 1.|0.98\n"
        b"FACT:DIAGNOSIS_CODE=S72.0|0.99\n"
        b"FACT:SURGERY_NAME=Fracture reduction and internal fixation|0.97\n"
        b"FACT:DISABILITY_RATE=15%|0.95\n"
        b"FACT:COPAYMENT_AMOUNT=2000000|0.96\n"
        b"FACT:NON_BENEFIT_AMOUNT=3000000|0.94\n"
        b"%%EOF"
    )
    client.post(
        f"/api/claims/{claim_id}/documents",
        data={"documentType": "MEDICAL_RECEIPT"},
        files={"file": ("injury_medical_record.pdf", doc_content, "application/pdf")},
    )

    client.post(f"/api/claims/{claim_id}/analysis")
    ocr_result = db_session.get(OCRResult, queue.ids[0])
    assert ocr_result is not None
    process_ocr(
        db_session,
        ocr_result,
        storage,
        DevelopmentOCRProvider(),
        DevelopmentExtractionProvider(),
    )
    db_session.commit()

    facts_res = client.get(f"/api/claims/{claim_id}/facts")
    for f in facts_res.json():
        client.post(f"/api/facts/{f['extracted_fact_id']}/confirm")

    # Assess
    assess_res = client.post(f"/api/claims/{claim_id}/assess")
    assert assess_res.status_code == 201
    assessments = assess_res.json()
    assert len(assessments) == 4

    # Calculate
    for assess in assessments:
        calc_res = client.post(f"/api/assessments/{assess['assessment_id']}/calculate")
        assert calc_res.status_code in (201, 200)

    calculations = client.get(f"/api/claims/{claim_id}/calculations").json()
    assert len(calculations) == 4

    # 1) 상해후유장해: 1억원 * 15% = 1,500만원
    dis_calc = next(c for c in calculations if c["final_amount"] == 15000000)
    assert dis_calc["final_amount"] == 15000000
    assert dis_calc["calculation_status"] == CalculationStatus.CALCULATED.value

    # 2) 상해수술비: 200만원 (100% 정액)
    surg_calc = next(c for c in calculations if c["final_amount"] == 2000000)
    assert surg_calc["final_amount"] == 2000000
    assert surg_calc["calculation_status"] == CalculationStatus.CALCULATED.value

    # 3) 급여 실손의료비: 200만원 - (200만원 * 20%) = 160만원
    ben_calc = next(c for c in calculations if c["final_amount"] == 1600000)
    assert ben_calc["final_amount"] == 1600000
    assert ben_calc["calculation_status"] == CalculationStatus.CALCULATED.value

    # 4) 비급여 실손의료비: 300만원 - (300만원 * 30%) = 210만원
    non_calc = next(c for c in calculations if c["final_amount"] == 2100000)
    assert non_calc["final_amount"] == 2100000
    assert non_calc["calculation_status"] == CalculationStatus.CALCULATED.value
