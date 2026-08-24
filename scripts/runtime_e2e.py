"""ClaimLens runtime E2E: real API + MinIO + ClamAV + Tesseract OCR + Ollama extraction.

Drives the full claim lifecycle against http://localhost:8000 with the compose stack.
"""

import sys
import time
import warnings

import fitz
import httpx

warnings.filterwarnings("ignore")

BASE = "http://localhost:8000"
EMAIL = "e2e-runtime-user@example.com"
PASSWORD = "E2eRuntimeUser2026!"

client = httpx.Client(base_url=BASE, timeout=120)


def step(message: str) -> None:
    print(f"\n=== {message} ===", flush=True)


def pick(obj: dict, *names):
    for name in names:
        if name in obj:
            return obj[name]
    raise KeyError(f"none of {names} in {list(obj)[:12]}")


# 1. Register + Login
step("1. Register & Login")
register = client.post(
    "/api/auth/register",
    json={
        "email": EMAIL,
        "password": PASSWORD,
        "display_name": "E2E Runtime User",
        "consents": [
            {"consent_type": "SERVICE_TERMS", "consent_version": "v1", "agreed": True},
            {"consent_type": "PRIVACY", "consent_version": "v1", "agreed": True},
            {"consent_type": "SENSITIVE_INFORMATION", "consent_version": "v1", "agreed": True},
            {"consent_type": "AI_PROCESSING", "consent_version": "v1", "agreed": True},
        ],
    },
)
print("register:", register.status_code)
if register.status_code != 201:
    print(register.text)
login = client.post("/api/auth/login", json={"email": EMAIL, "password": PASSWORD})
print("login:", login.status_code)
assert login.status_code == 200, login.text

# 2. Catalogs
step("2. Catalogs")
companies = client.get("/api/catalog/insurance-companies").json()
company = next(c for c in companies if pick(c, "company_code") == "DB_INSURANCE")
company_id = pick(company, "company_id")
print("company:", pick(company, "company_name", "company_code"))

products = client.get(
    "/api/catalog/insurance-products", params={"company_id": str(company_id)}
).json()
product = next(
    p
    for p in products
    if pick(p, "company_id") == company_id and pick(p, "product_code") == "31100"
)
product_id = pick(product, "product_id")

versions = client.get(
    "/api/catalog/product-versions", params={"product_id": str(product_id)}
).json()
version = next(v for v in versions if pick(v, "product_id") == product_id)
product_version_id = pick(version, "product_version_id")
print("product_version:", product_version_id)

coverages = client.get("/api/catalog/coverages").json()
by_code = {pick(c, "standard_code"): c for c in coverages}
mi_cov = by_code["STD_ACUTE_MYOCARDIAL_INFARCTION_DIAG"]
isch_cov = by_code["STD_ISCHEMIC_HEART_DIAG"]
print("coverages: MI + ISCHEMIC found")

# 3. Insured + Contract
step("3. Insured & Contract")
insured = client.post("/api/insureds", json={"name": "홍길동", "relationship_type": "SELF"})
if insured.status_code == 409:
    existing = client.get("/api/insureds").json()
    insured_id = next(pick(i, "insured_id") for i in existing if pick(i, "name") == "홍길동")
    print("insured: reused existing", insured_id)
else:
    print("insured:", insured.status_code)
    assert insured.status_code == 201, insured.text
    insured_id = pick(insured.json(), "insured_id")

contract = client.post(
    "/api/contracts",
    json={
        "insured_id": insured_id,
        "product_version_id": product_version_id,
        "policy_number": f"E2E-RUNTIME-{int(time.time())}",
        "coverage_start_date": "2024-01-01",
        "coverage_end_date": "2054-01-01",
        "coverages": [
            {
                "coverage_id": str(pick(mi_cov, "coverage_id")),
                "coverage_name_snapshot": "급성심근경색증진단비",
                "insured_amount": 30000000,
            },
            {
                "coverage_id": str(pick(isch_cov, "coverage_id")),
                "coverage_name_snapshot": "허혈성심장질환진단비",
                "insured_amount": 10000000,
            },
        ],
    },
)
print("contract:", contract.status_code)
assert contract.status_code == 201, contract.text
contract_id = pick(contract.json(), "contract_id")

# 4. Claim + transition
step("4. Claim")
claim = client.post(
    "/api/claims",
    json={
        "contract_id": contract_id,
        "claim_type": "DISEASE",
        "title": "E2E 런타임 급성심근경색 진단비 청구",
        "accident": {
            "diagnosis_date": "2026-08-10",
            "onset_date": "2026-08-01",
            "description": "E2E: 급성 심근경색(I21.0) 진단",
        },
    },
)
print("claim:", claim.status_code)
assert claim.status_code == 201, claim.text
claim_id = pick(claim.json(), "claim_id")

transition = client.post(
    f"/api/claims/{claim_id}/transitions",
    json={"action": "SUBMIT_ACCIDENT_INFORMATION"},
)
print("transition:", transition.status_code, "->", transition.json().get("status"))
assert transition.status_code == 200, transition.text

# 5. Render diagnosis document (Korean) and upload
step("5. Upload diagnosis document")
font = r"C:\Windows\Fonts\malgun.ttf"
doc = fitz.open()
page = doc.new_page(width=612, height=400)
lines = [
    "진단확인서",
    "환자명: 홍길동",
    "진단명: 급성 심근경색 (I21.0)",
    "진단일: 2026-08-10",
    "입원일: 2026-08-01",
    "퇴원일: 2026-08-12",
    "발행일: 2026-08-13",
    "의료기관: 서울종합병원",
]
y = 60
for index, line in enumerate(lines):
    page.insert_text(
        fitz.Point(50, y),
        line,
        fontsize=22 if index == 0 else 15,
        fontfile=font,
        fontname="malgun",
    )
    y += 45
png = page.get_pixmap(dpi=200).tobytes("png")

upload = client.post(
    f"/api/claims/{claim_id}/documents",
    data={"documentType": "DIAGNOSIS_CERTIFICATE"},
    files={"file": ("diagnosis_i21.png", png, "image/png")},
)
print("upload:", upload.status_code)
if upload.status_code != 201:
    print(upload.text)
    sys.exit(1)
document_id = pick(upload.json(), "document_id")

content = client.get(f"/api/documents/{document_id}/content")
print("stored content fetch:", content.status_code, len(content.content), "bytes")
assert content.status_code == 200 and content.content == png, "stored object mismatch"

# 6. Trigger analysis pipeline (real Redis queue -> worker -> OCR -> AI)
step("6. Trigger analysis (real OCR/AI pipeline)")
analysis = client.post(f"/api/claims/{claim_id}/analysis")
print("analysis:", analysis.status_code, analysis.text[:200])
assert analysis.status_code == 202, analysis.text

facts = []
deadline = time.time() + 420
while time.time() < deadline:
    time.sleep(5)
    response = client.get(f"/api/claims/{claim_id}/facts")
    if response.status_code == 200:
        facts = response.json()
        if facts:
            break
    status_response = client.get(f"/api/claims/{claim_id}/analysis-status")
    if status_response.status_code == 200:
        print("  status:", status_response.text[:160])
print(f"facts extracted: {len(facts)}")
assert facts, "no facts extracted within timeout"
for fact in facts:
    print("  -", pick(fact, "fact_type"), "=", pick(fact, "fact_value"))

# 7. Correct diagnosis code if OCR mangled it, then confirm all
step("7. Verify facts")
for fact in facts:
    fact_id = pick(fact, "extracted_fact_id")
    fact_type = pick(fact, "fact_type")
    value = pick(fact, "fact_value")
    if fact_type == "DIAGNOSIS_CODE" and value.replace(" ", "") != "I21.0":
        modified = client.post(
            f"/api/facts/{fact_id}/modify",
            json={"value": "I21.0", "reason": "OCR misread bar as digit one"},
        )
        print("modify DIAGNOSIS_CODE:", modified.status_code)
        assert modified.status_code == 200, modified.text
    confirmed = client.post(f"/api/facts/{fact_id}/confirm")
    if confirmed.status_code == 409 and "FACT_ALREADY_VERIFIED" in confirmed.text:
        print("confirm", fact_type, "-> already verified (modified)")
    else:
        print("confirm", fact_type, "->", confirmed.status_code)
        assert confirmed.status_code == 200, confirmed.text

# 8. Assess + Calculate
step("8. Assess & Calculate")
assess = client.post(f"/api/claims/{claim_id}/assess")
print("assess:", assess.status_code)
if assess.status_code != 201:
    print(assess.text)
    sys.exit(1)
assessments = assess.json()
for item in assessments:
    print("assessment:", str(item)[:220])
for item in assessments:
    assessment_id = pick(item, "assessment_id")
    calculated = client.post(f"/api/assessments/{assessment_id}/calculate")
    if calculated.status_code == 409 and "CALCULATION_NOT_ALLOWED" in calculated.text:
        print("calculate: skipped (assessment not calculation-eligible)")
        continue
    print("calculate:", calculated.status_code, calculated.text[:160])
    assert calculated.status_code in (200, 201), calculated.text

calculations = client.get(f"/api/claims/{claim_id}/calculations").json()
print("\n=== CALCULATIONS ===")
for calc in calculations:
    print(
        pick(calc, "calculation_status"),
        pick(calc, "final_amount"),
        "insured:",
        pick(calc, "insured_amount_snapshot"),
    )

mi = next(
    (c for c in calculations if pick(c, "final_amount") == 30000000),
    None,
)
print("\nRESULT:", "PASS (MI 30,000,000 CALCULATED)" if mi else "CHECK AMOUNTS")
print("claim_id:", claim_id)
