"use client";

import Link from "next/link";
import { useEffect, useState } from "react";

const api = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000";

type CatalogItem = {
  company_id?: string;
  product_id?: string;
  product_version_id?: string;
  coverage_id?: string;
  company_name?: string;
  product_name?: string;
  version_name?: string;
  coverage_name?: string;
};

type InsuredItem = {
  insured_id: string;
  name: string;
  birth_date: string | null;
  gender: string;
};

type CoverageRow = {
  coverageId: string;
  name: string;
  amount: number;
};

type DirectFactRow = {
  factType: string;
  value: string;
};

type UploadedFileItem = {
  file: File;
  documentType: string;
};

type IntakeResult = {
  claim_id: string;
  claim_number: string;
  contract_id: string;
  insured_id: string;
  claim_status: string;
  documents_count: number;
  assessments_count: number;
  calculations_count: number;
  total_benefit_amount: number;
  review_id: string | null;
  review_status: string | null;
  redirect_url: string;
};

const FACT_TYPES = [
  { value: "DIAGNOSIS_CODE", label: "질병분류기호 (KCD 코드, 예: I21.9, C16.0)" },
  { value: "DIAGNOSIS_NAME", label: "진단명 (질병명, 예: 급성 심근경색증)" },
  { value: "DIAGNOSIS_DATE", label: "진단일자 (YYYY-MM-DD)" },
  { value: "SURGERY_NAME", label: "수술명 (예: 관상동맥 스텐트삽입술)" },
  { value: "SURGERY_DATE", label: "수술일자 (YYYY-MM-DD)" },
  { value: "HOSPITAL_ADMISSION_DATE", label: "입원일자 (YYYY-MM-DD)" },
  { value: "HOSPITAL_DISCHARGE_DATE", label: "퇴원일자 (YYYY-MM-DD)" },
  { value: "ACCIDENT_DATE", label: "사고일자 (YYYY-MM-DD)" },
  { value: "MEDICAL_FACILITY", label: "의료기관명 (예: 서울아산병원)" },
];

const DOCUMENT_TYPES = [
  { value: "DIAGNOSIS_CERTIFICATE", label: "진단서 (DIAGNOSIS_CERTIFICATE)" },
  { value: "SURGERY_RECORD", label: "수술확인서 (SURGERY_RECORD)" },
  { value: "HOSPITALIZATION_RECORD", label: "입퇴원확인서 (HOSPITALIZATION_RECORD)" },
  { value: "MEDICAL_BILL", label: "진료비영수증/세부내역서 (MEDICAL_BILL)" },
  { value: "OTHER", label: "기타 소명서류 (OTHER)" },
];

export default function FastIntakePage() {
  // Catalog states
  const [companies, setCompanies] = useState<CatalogItem[]>([]);
  const [products, setProducts] = useState<CatalogItem[]>([]);
  const [versions, setVersions] = useState<CatalogItem[]>([]);
  const [coveragesCatalog, setCoveragesCatalog] = useState<CatalogItem[]>([]);
  const [insureds, setInsureds] = useState<InsuredItem[]>([]);

  // Form states - Insured
  const [insuredMode, setInsuredMode] = useState<"new" | "existing">("new");
  const [selectedInsuredId, setSelectedInsuredId] = useState("");
  const [insuredName, setInsuredName] = useState("");
  const [insuredBirthDate, setInsuredBirthDate] = useState("");
  const [insuredGender, setInsuredGender] = useState("MALE");
  const [insuredRelationship, setInsuredRelationship] = useState("SELF");

  // Form states - Contract
  const [selectedCompanyId, setSelectedCompanyId] = useState("");
  const [selectedProductId, setSelectedProductId] = useState("");
  const [selectedVersionId, setSelectedVersionId] = useState("");
  const [policyNumber, setPolicyNumber] = useState("");
  const [contractDate, setContractDate] = useState("2025-01-10");
  const [coverageStartDate, setCoverageStartDate] = useState("2025-01-10");
  const [coverageEndDate, setCoverageEndDate] = useState("2045-01-10");
  const [coverageRows, setCoverageRows] = useState<CoverageRow[]>([
    { coverageId: "", name: "", amount: 50000000 },
  ]);

  // Form states - Incident
  const [claimType, setClaimType] = useState("DISEASE");
  const [claimTitle, setClaimTitle] = useState("");
  const [diagnosisDate, setDiagnosisDate] = useState("2026-07-10");
  const [accidentDate, setAccidentDate] = useState("");
  const [incidentLocation, setIncidentLocation] = useState("");
  const [description, setDescription] = useState("");

  // Form states - Files & Direct facts
  const [files, setFiles] = useState<UploadedFileItem[]>([]);
  const [directFacts, setDirectFacts] = useState<DirectFactRow[]>([]);
  const [showDirectFacts, setShowDirectFacts] = useState(false);

  // Form states - Options
  const [autoAnalyze, setAutoAnalyze] = useState(true);
  const [autoConfirmFacts, setAutoConfirmFacts] = useState(true);
  const [autoAssess, setAutoAssess] = useState(true);
  const [createReview, setCreateReview] = useState(true);
  const [reviewReason, setReviewReason] = useState(
    "원스톱 사건 접수에 따른 손해사정 심사 및 보고서 작성"
  );

  // Status & Results
  const [submitting, setSubmitting] = useState(false);
  const [statusMessage, setStatusMessage] = useState("");
  const [errorMessage, setErrorMessage] = useState("");
  const [result, setResult] = useState<IntakeResult | null>(null);

  // Load catalogs on mount
  useEffect(() => {
    Promise.all([
      fetch(`${api}/api/catalog/insurance-companies`, { credentials: "include" })
        .then((r) => (r.ok ? r.json() : []))
        .catch(() => []),
      fetch(`${api}/api/catalog/coverages`, { credentials: "include" })
        .then((r) => (r.ok ? r.json() : []))
        .catch(() => []),
      fetch(`${api}/api/insureds`, { credentials: "include" })
        .then((r) => (r.ok ? r.json() : []))
        .catch(() => []),
    ]).then(([comp, covs, ins]) => {
      setCompanies(comp);
      setCoveragesCatalog(covs);
      setInsureds(ins);
    });
  }, []);

  async function handleCompanyChange(compId: string) {
    setSelectedCompanyId(compId);
    setSelectedProductId("");
    setSelectedVersionId("");
    if (!compId) {
      setProducts([]);
      setVersions([]);
      return;
    }
    const res = await fetch(`${api}/api/catalog/insurance-products?company_id=${compId}`, {
      credentials: "include",
    });
    if (res.ok) {
      setProducts(await res.json());
    }
  }

  async function handleProductChange(prodId: string) {
    setSelectedProductId(prodId);
    setSelectedVersionId("");
    if (!prodId) {
      setVersions([]);
      return;
    }
    const res = await fetch(`${api}/api/catalog/product-versions?product_id=${prodId}`, {
      credentials: "include",
    });
    if (res.ok) {
      const vers = await res.json();
      setVersions(vers);
      if (vers.length > 0) {
        setSelectedVersionId(vers[0].product_version_id ?? "");
      }
    }
  }

  // Presets / Quick Fillers
  function applyPreset(type: "AMI" | "CANCER" | "FRACTURE") {
    if (type === "AMI") {
      setInsuredName("김철수");
      setInsuredBirthDate("1978-08-20");
      setInsuredGender("MALE");
      setClaimType("DISEASE");
      setClaimTitle("급성심근경색증 진단비 및 수술비 사정의뢰건");
      setDiagnosisDate("2026-07-10");
      setDescription("급성 흉통으로 응급실 내원, 급성 심근경색증(I21.9) 확진 후 스텐트삽입술 시행");
      setPolicyNumber("POL-2026-AMI-001");
      setDirectFacts([
        { factType: "DIAGNOSIS_CODE", value: "I21.9" },
        { factType: "DIAGNOSIS_NAME", value: "Acute myocardial infarction" },
        { factType: "DIAGNOSIS_DATE", value: "2026-07-10" },
      ]);
      setShowDirectFacts(true);
      if (coveragesCatalog.length > 0) {
        const c = coveragesCatalog[0];
        setCoverageRows([
          {
            coverageId: c.coverage_id ?? "",
            name: c.coverage_name ?? "급성심근경색증진단비",
            amount: 50000000,
          },
        ]);
      }
    } else if (type === "CANCER") {
      setInsuredName("박영희");
      setInsuredBirthDate("1982-11-04");
      setInsuredGender("FEMALE");
      setClaimType("DISEASE");
      setClaimTitle("위선암종(일반암) 진단비 사정의뢰건");
      setDiagnosisDate("2026-06-15");
      setDescription("건강검진 위내시경 조직검사에서 위선암종(C16.0) 확진 판정");
      setPolicyNumber("POL-2026-CAN-002");
      setDirectFacts([
        { factType: "DIAGNOSIS_CODE", value: "C16.0" },
        { factType: "DIAGNOSIS_NAME", value: "Malignant neoplasm of stomach" },
        { factType: "DIAGNOSIS_DATE", value: "2026-06-15" },
      ]);
      setShowDirectFacts(true);
      if (coveragesCatalog.length > 0) {
        const c = coveragesCatalog[0];
        setCoverageRows([
          {
            coverageId: c.coverage_id ?? "",
            name: c.coverage_name ?? "일반암진단비",
            amount: 30000000,
          },
        ]);
      }
    } else if (type === "FRACTURE") {
      setInsuredName("이민수");
      setInsuredBirthDate("1995-03-12");
      setInsuredGender("MALE");
      setClaimType("INJURY");
      setClaimTitle("교통사고 골절 및 관혈정복술 사정의뢰건");
      setAccidentDate("2026-08-01");
      setIncidentLocation("서울시 강남구 테헤란로 교차로");
      setDescription("오토바이 교통사고로 우측 경골 골절(S82.1) 수상하여 수술 시행");
      setPolicyNumber("POL-2026-FRAC-003");
      setDirectFacts([
        { factType: "DIAGNOSIS_CODE", value: "S82.1" },
        { factType: "ACCIDENT_DATE", value: "2026-08-01" },
      ]);
      setShowDirectFacts(true);
    }
  }

  function handleFileAdd(e: React.ChangeEvent<HTMLInputElement>) {
    if (!e.target.files) return;
    const selected = Array.from(e.target.files);
    const newItems: UploadedFileItem[] = selected.map((f) => ({
      file: f,
      documentType: "DIAGNOSIS_CERTIFICATE",
    }));
    setFiles((prev) => [...prev, ...newItems]);
    e.target.value = "";
  }

  function handleRemoveFile(idx: number) {
    setFiles((prev) => prev.filter((_, i) => i !== idx));
  }

  function handleAddCoverageRow() {
    setCoverageRows((prev) => [...prev, { coverageId: "", name: "", amount: 10000000 }]);
  }

  function handleRemoveCoverageRow(idx: number) {
    setCoverageRows((prev) => prev.filter((_, i) => i !== idx));
  }

  function handleAddDirectFact() {
    setDirectFacts((prev) => [...prev, { factType: "DIAGNOSIS_CODE", value: "" }]);
  }

  function handleRemoveDirectFact(idx: number) {
    setDirectFacts((prev) => prev.filter((_, i) => i !== idx));
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setErrorMessage("");
    setStatusMessage("사건 접수 데이터를 검증하고 있습니다...");
    setSubmitting(true);
    setResult(null);

    // Prepare payload
    const payloadData = {
      insured:
        insuredMode === "existing"
          ? { insured_id: selectedInsuredId }
          : {
              name: insuredName.trim(),
              birth_date: insuredBirthDate || null,
              gender: insuredGender,
              relationship_type: insuredRelationship,
            },
      contract: {
        product_version_id: selectedVersionId || undefined,
        policy_number: policyNumber || undefined,
        contract_date: contractDate || null,
        coverage_start_date: coverageStartDate || null,
        coverage_end_date: coverageEndDate || null,
        coverages: coverageRows
          .filter((r) => r.coverageId)
          .map((r) => ({
            coverage_id: r.coverageId,
            coverage_name_snapshot: r.name || "보장담보",
            insured_amount: Number(r.amount),
          })),
      },
      incident: {
        claim_type: claimType,
        title: claimTitle.trim() || undefined,
        accident_date: claimType === "INJURY" ? accidentDate || null : null,
        diagnosis_date: claimType === "DISEASE" ? diagnosisDate || null : null,
        location: claimType === "INJURY" ? incidentLocation || null : null,
        description: description.trim() || undefined,
      },
      direct_facts: directFacts
        .filter((df) => df.factType && df.value.trim())
        .map((df) => ({ fact_type: df.factType, value: df.value.trim() })),
      documents_metadata: files.map((item) => ({
        filename: item.file.name,
        document_type: item.documentType,
      })),
      options: {
        auto_analyze: autoAnalyze,
        auto_confirm_facts: autoConfirmFacts,
        auto_assess: autoAssess,
        create_review: createReview,
        review_reason: reviewReason.trim(),
      },
    };

    try {
      setStatusMessage("계약 등록, 서류 업로드 및 인공지능 분석 파이프라인을 가동 중입니다...");
      const formData = new FormData();
      formData.append("payload", JSON.stringify(payloadData));
      for (const item of files) {
        formData.append("files", item.file, item.file.name);
      }

      const res = await fetch(`${api}/api/intake`, {
        method: "POST",
        credentials: "include",
        body: formData,
      });

      const body = await res.json().catch(() => null);

      if (!res.ok) {
        throw new Error(body?.error?.message ?? `접수 처리 실패 (코드: ${res.status})`);
      }

      setResult(body as IntakeResult);
      setStatusMessage("원스톱 사건 접수 및 사정 착수가 성공적으로 완료되었습니다!");
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      setErrorMessage(msg);
      setStatusMessage("");
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <main>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline" }}>
        <div>
          <h1 style={{ margin: "0 0 8px 0" }}>⚡ 원스톱 사건 접수 (Fast Intake)</h1>
          <p className="notice" style={{ marginTop: 0 }}>
            손해사정 1인 시범운영 전용: 피보험자, 보험계약, 사고정보, 의료서류를 단일 화면에서
            일괄 등록하고 즉시 손해사정 워크스페이스로 착수합니다.
          </p>
        </div>
        <div style={{ display: "flex", gap: "8px" }}>
          <Link href="/reviews" className="badge approved" style={{ textDecoration: "none", padding: "8px 12px" }}>
            📋 내 배정 검토 목록
          </Link>
        </div>
      </div>

      {/* Preset Buttons */}
      <div
        style={{
          background: "#eef4ff",
          border: "1px solid #c7d7fe",
          borderRadius: "8px",
          padding: "12px 16px",
          marginBottom: "20px",
          display: "flex",
          alignItems: "center",
          gap: "10px",
          flexWrap: "wrap",
        }}
      >
        <strong style={{ color: "#3538cd", fontSize: "14px" }}>🧪 빠른 테스트 템플릿:</strong>
        <button
          type="button"
          onClick={() => applyPreset("AMI")}
          style={{ background: "#3538cd", fontSize: "13px", padding: "6px 12px" }}
        >
          급성심근경색증 (5천만원)
        </button>
        <button
          type="button"
          onClick={() => applyPreset("CANCER")}
          style={{ background: "#067647", fontSize: "13px", padding: "6px 12px" }}
        >
          위암 진단비 (3천만원)
        </button>
        <button
          type="button"
          onClick={() => applyPreset("FRACTURE")}
          style={{ background: "#b54708", fontSize: "13px", padding: "6px 12px" }}
        >
          골절 및 상해 (사고접수)
        </button>
      </div>

      {statusMessage && (
        <div
          style={{
            padding: "14px 18px",
            background: "#ecfdf3",
            border: "1px solid #abefc6",
            borderRadius: "8px",
            color: "#067647",
            fontWeight: "bold",
            marginBottom: "20px",
          }}
        >
          {statusMessage}
        </div>
      )}

      {errorMessage && (
        <div
          style={{
            padding: "14px 18px",
            background: "#fef3f2",
            border: "1px solid #fecdca",
            borderRadius: "8px",
            color: "#b42318",
            fontWeight: "bold",
            marginBottom: "20px",
          }}
        >
          ⚠️ {errorMessage}
        </div>
      )}

      {/* Success Result Modal / Banner */}
      {result && (
        <div
          className="card"
          style={{
            border: "2px solid #067647",
            background: "#f6fef9",
            marginBottom: "24px",
            boxShadow: "0 4px 12px rgba(6,118,71,0.1)",
          }}
        >
          <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
            <div>
              <span className="badge approved" style={{ fontSize: "14px", padding: "6px 12px" }}>
                ✅ 사정 착수 완료 ({result.claim_status})
              </span>
              <h2 style={{ margin: "10px 0 6px 0", color: "#067647" }}>
                Case {result.claim_number} 접수 완료
              </h2>
              <p style={{ margin: 0, color: "#344054" }}>
                총 사정결정금액:{" "}
                <strong style={{ fontSize: "18px", color: "#155eef" }}>
                  ₩ {result.total_benefit_amount.toLocaleString("ko-KR")} 원
                </strong>{" "}
                · 첨부서류: {result.documents_count}건 · 평가담보: {result.assessments_count}건
              </p>
            </div>
            <div style={{ display: "flex", gap: "10px" }}>
              {result.review_id && (
                <>
                  <Link
                    href={`/reviews/${result.review_id}`}
                    style={{
                      background: "#155eef",
                      color: "white",
                      padding: "12px 18px",
                      borderRadius: "6px",
                      textDecoration: "none",
                      fontWeight: "bold",
                    }}
                  >
                    📝 손해사정서 작성하기
                  </Link>
                  <Link
                    href={`/reviews/${result.review_id}/report`}
                    target="_blank"
                    style={{
                      background: "#067647",
                      color: "white",
                      padding: "12px 18px",
                      borderRadius: "6px",
                      textDecoration: "none",
                      fontWeight: "bold",
                    }}
                  >
                    🖨️ 손해사정보고서 미리보기
                  </Link>
                </>
              )}
            </div>
          </div>
        </div>
      )}

      <form onSubmit={handleSubmit}>
        {/* Step 1: Insured Information */}
        <section className="card">
          <h2>1. 피보험자 정보</h2>
          <div style={{ display: "flex", gap: "16px", marginBottom: "12px" }}>
            <label style={{ display: "flex", alignItems: "center", gap: "6px", cursor: "pointer" }}>
              <input
                type="radio"
                name="insuredMode"
                value="new"
                checked={insuredMode === "new"}
                onChange={() => setInsuredMode("new")}
              />
              신규 고객 직접 입력
            </label>
            <label style={{ display: "flex", alignItems: "center", gap: "6px", cursor: "pointer" }}>
              <input
                type="radio"
                name="insuredMode"
                value="existing"
                checked={insuredMode === "existing"}
                onChange={() => setInsuredMode("existing")}
                disabled={insureds.length === 0}
              />
              기존 등록 고객 선택 ({insureds.length}명)
            </label>
          </div>

          {insuredMode === "existing" ? (
            <label>
              기존 피보험자 선택
              <select
                value={selectedInsuredId}
                onChange={(e) => setSelectedInsuredId(e.target.value)}
                required
              >
                <option value="">고객 선택</option>
                {insureds.map((ins) => (
                  <option key={ins.insured_id} value={ins.insured_id}>
                    {ins.name} ({ins.birth_date ?? "생년월일 미상"}, {ins.gender})
                  </option>
                ))}
              </select>
            </label>
          ) : (
            <div className="grid">
              <label>
                피보험자 성명 *
                <input
                  value={insuredName}
                  onChange={(e) => setInsuredName(e.target.value)}
                  placeholder="예: 홍길동"
                  required
                />
              </label>
              <label>
                생년월일 (생일)
                <input
                  type="date"
                  value={insuredBirthDate}
                  onChange={(e) => setInsuredBirthDate(e.target.value)}
                />
              </label>
              <label>
                성별
                <select value={insuredGender} onChange={(e) => setInsuredGender(e.target.value)}>
                  <option value="MALE">남성 (MALE)</option>
                  <option value="FEMALE">여성 (FEMALE)</option>
                  <option value="UNKNOWN">미상 (UNKNOWN)</option>
                </select>
              </label>
              <label>
                계약자와의 관계
                <select
                  value={insuredRelationship}
                  onChange={(e) => setInsuredRelationship(e.target.value)}
                >
                  <option value="SELF">본인 (SELF)</option>
                  <option value="SPOUSE">배우자 (SPOUSE)</option>
                  <option value="CHILD">자녀 (CHILD)</option>
                  <option value="OTHER">의뢰인/기타 (OTHER)</option>
                </select>
              </label>
            </div>
          )}
        </section>

        {/* Step 2: Contract & Subscribed Coverages */}
        <section className="card">
          <h2>2. 보험계약 및 보장담보 정보</h2>
          <div className="grid">
            <label>
              보험회사 *
              <select
                value={selectedCompanyId}
                onChange={(e) => void handleCompanyChange(e.target.value)}
                required
              >
                <option value="">보험사 선택</option>
                {companies.map((c) => (
                  <option key={c.company_id} value={c.company_id}>
                    {c.company_name}
                  </option>
                ))}
              </select>
            </label>
            <label>
              보험상품 *
              <select
                value={selectedProductId}
                onChange={(e) => void handleProductChange(e.target.value)}
                required
                disabled={!selectedCompanyId}
              >
                <option value="">상품 선택</option>
                {products.map((p) => (
                  <option key={p.product_id} value={p.product_id}>
                    {p.product_name}
                  </option>
                ))}
              </select>
            </label>
            <label>
              상품 버전 *
              <select
                value={selectedVersionId}
                onChange={(e) => setSelectedVersionId(e.target.value)}
                required
                disabled={!selectedProductId}
              >
                <option value="">버전 선택</option>
                {versions.map((v) => (
                  <option key={v.product_version_id} value={v.product_version_id}>
                    {v.version_name}
                  </option>
                ))}
              </select>
            </label>
            <label>
              보험증권번호
              <input
                value={policyNumber}
                onChange={(e) => setPolicyNumber(e.target.value)}
                placeholder="예: 2026-POL-09118"
              />
            </label>
            <label>
              계약일자
              <input
                type="date"
                value={contractDate}
                onChange={(e) => setContractDate(e.target.value)}
              />
            </label>
            <label>
              보장개시일
              <input
                type="date"
                value={coverageStartDate}
                onChange={(e) => setCoverageStartDate(e.target.value)}
              />
            </label>
            <label>
              보장종료일
              <input
                type="date"
                value={coverageEndDate}
                onChange={(e) => setCoverageEndDate(e.target.value)}
              />
            </label>
          </div>

          <h3 style={{ marginTop: "16px", marginBottom: "8px" }}>가입담보 설정</h3>
          {coverageRows.map((row, idx) => (
            <div
              key={idx}
              style={{
                display: "grid",
                gridTemplateColumns: "1fr 1fr 1fr auto",
                gap: "10px",
                alignItems: "center",
                marginBottom: "8px",
              }}
            >
              <select
                value={row.coverageId}
                onChange={(e) => {
                  const target = coveragesCatalog.find((c) => c.coverage_id === e.target.value);
                  setCoverageRows((prev) =>
                    prev.map((r, i) =>
                      i === idx
                        ? {
                            ...r,
                            coverageId: e.target.value,
                            name: target?.coverage_name ?? r.name,
                          }
                        : r
                    )
                  );
                }}
                required
              >
                <option value="">담보 마스터 선택</option>
                {coveragesCatalog.map((c) => (
                  <option key={c.coverage_id} value={c.coverage_id}>
                    {c.coverage_name}
                  </option>
                ))}
              </select>
              <input
                placeholder="가입 당시 담보명"
                value={row.name}
                onChange={(e) =>
                  setCoverageRows((prev) =>
                    prev.map((r, i) => (i === idx ? { ...r, name: e.target.value } : r))
                  )
                }
                required
              />
              <input
                type="number"
                step="10000"
                min="0"
                placeholder="가입금액 (원)"
                value={row.amount}
                onChange={(e) =>
                  setCoverageRows((prev) =>
                    prev.map((r, i) =>
                      i === idx ? { ...r, amount: Number(e.target.value) } : r
                    )
                  )
                }
                required
              />
              {coverageRows.length > 1 && (
                <button
                  type="button"
                  className="reject"
                  onClick={() => handleRemoveCoverageRow(idx)}
                >
                  삭제
                </button>
              )}
            </div>
          ))}
          <button
            type="button"
            className="secondary"
            onClick={handleAddCoverageRow}
            style={{ marginTop: "6px", fontSize: "13px" }}
          >
            + 담보 추가
          </button>
        </section>

        {/* Step 3: Incident Information */}
        <section className="card">
          <h2>3. 사고 및 질병 정보</h2>
          <div style={{ display: "flex", gap: "20px", marginBottom: "12px" }}>
            <label style={{ display: "flex", alignItems: "center", gap: "6px", cursor: "pointer" }}>
              <input
                type="radio"
                name="claimType"
                value="DISEASE"
                checked={claimType === "DISEASE"}
                onChange={() => setClaimType("DISEASE")}
              />
              질병 (DISEASE)
            </label>
            <label style={{ display: "flex", alignItems: "center", gap: "6px", cursor: "pointer" }}>
              <input
                type="radio"
                name="claimType"
                value="INJURY"
                checked={claimType === "INJURY"}
                onChange={() => setClaimType("INJURY")}
              />
              상해 / 재해 (INJURY)
            </label>
            <label style={{ display: "flex", alignItems: "center", gap: "6px", cursor: "pointer" }}>
              <input
                type="radio"
                name="claimType"
                value="OTHER"
                checked={claimType === "OTHER"}
                onChange={() => setClaimType("OTHER")}
              />
              기타 (OTHER)
            </label>
          </div>

          <label>
            사건 / 청구 제목
            <input
              value={claimTitle}
              onChange={(e) => setClaimTitle(e.target.value)}
              placeholder="예: 급성심근경색증 진단비 및 수술비 사정의뢰건"
            />
          </label>

          <div className="grid">
            {claimType === "DISEASE" ? (
              <label>
                진단일자 *
                <input
                  type="date"
                  value={diagnosisDate}
                  onChange={(e) => setDiagnosisDate(e.target.value)}
                  required
                />
              </label>
            ) : (
              <>
                <label>
                  사고일자 *
                  <input
                    type="date"
                    value={accidentDate}
                    onChange={(e) => setAccidentDate(e.target.value)}
                    required
                  />
                </label>
                <label>
                  사고장소
                  <input
                    value={incidentLocation}
                    onChange={(e) => setIncidentLocation(e.target.value)}
                    placeholder="예: 서울시 강남구 테헤란로"
                  />
                </label>
              </>
            )}
          </div>

          <label>
            사고 또는 진단 경위 (소견/경위 요약)
            <textarea
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              placeholder="환자의 내원 경위, 주증상, 진료과 및 확진 경위를 입력하세요."
            />
          </label>
        </section>

        {/* Step 4: Medical Documents & Direct Facts */}
        <section className="card">
          <h2>4. 의료 서류 첨부 및 직접 팩트 입력</h2>
          <div
            style={{
              border: "2px dashed #b2ccff",
              background: "#f8faff",
              borderRadius: "8px",
              padding: "20px",
              textAlign: "center",
              marginBottom: "16px",
            }}
          >
            <p style={{ margin: "0 0 8px 0", color: "#155eef", fontWeight: "bold" }}>
              📁 진단서, 수술확인서, 입퇴원확인서, 진료비영수증 첨부
            </p>
            <input
              type="file"
              multiple
              accept=".pdf,.jpg,.jpeg,.png,.heic"
              onChange={handleFileAdd}
              style={{ display: "inline-block" }}
            />
            <p style={{ margin: "6px 0 0 0", fontSize: "12px", color: "#667085" }}>
              지원 형식: PDF, JPG, PNG, HEIC (파일별 최대 25MB)
            </p>
          </div>

          {files.length > 0 && (
            <div style={{ marginBottom: "16px" }}>
              <h4>첨부된 의료서류 목록 ({files.length}건)</h4>
              {files.map((item, idx) => (
                <div
                  key={idx}
                  style={{
                    display: "grid",
                    gridTemplateColumns: "1fr 200px auto",
                    gap: "10px",
                    alignItems: "center",
                    padding: "8px",
                    background: "#f9fafb",
                    border: "1px solid #eaecf0",
                    borderRadius: "6px",
                    marginBottom: "6px",
                  }}
                >
                  <div>
                    <strong>{item.file.name}</strong>
                    <span style={{ fontSize: "12px", color: "#667085", marginLeft: "8px" }}>
                      ({(item.file.size / 1024).toFixed(1)} KB)
                    </span>
                  </div>
                  <select
                    value={item.documentType}
                    onChange={(e) => {
                      const val = e.target.value;
                      setFiles((prev) =>
                        prev.map((f, i) => (i === idx ? { ...f, documentType: val } : f))
                      );
                    }}
                  >
                    {DOCUMENT_TYPES.map((dt) => (
                      <option key={dt.value} value={dt.value}>
                        {dt.label}
                      </option>
                    ))}
                  </select>
                  <button
                    type="button"
                    className="reject"
                    onClick={() => handleRemoveFile(idx)}
                    style={{ padding: "4px 8px", fontSize: "12px" }}
                  >
                    삭제
                  </button>
                </div>
              ))}
            </div>
          )}

          {/* Direct Facts Accordion */}
          <div>
            <button
              type="button"
              className="secondary"
              onClick={() => setShowDirectFacts(!showDirectFacts)}
              style={{ fontSize: "13px" }}
            >
              {showDirectFacts ? "▼ 직접 의료 팩트 입력 접기" : "▶ 서류 대신/함께 직접 팩트 입력하기"}
            </button>

            {showDirectFacts && (
              <div
                style={{
                  marginTop: "12px",
                  padding: "12px",
                  background: "#f8fafc",
                  borderRadius: "8px",
                  border: "1px solid #eaecf0",
                }}
              >
                <p style={{ margin: "0 0 10px 0", fontSize: "13px", color: "#475467" }}>
                  💡 종이 서류를 보며 직접 KCD 질병분류기호나 수술명을 입력하면, 즉시 검증된
                  팩트(EXPERT_CONFIRMED)로 등재되어 판정 및 계산에 즉각 반영됩니다.
                </p>
                {directFacts.map((df, idx) => (
                  <div
                    key={idx}
                    style={{
                      display: "grid",
                      gridTemplateColumns: "1fr 1fr auto",
                      gap: "10px",
                      marginBottom: "8px",
                    }}
                  >
                    <select
                      value={df.factType}
                      onChange={(e) => {
                        const val = e.target.value;
                        setDirectFacts((prev) =>
                          prev.map((r, i) => (i === idx ? { ...r, factType: val } : r))
                        );
                      }}
                    >
                      {FACT_TYPES.map((ft) => (
                        <option key={ft.value} value={ft.value}>
                          {ft.label}
                        </option>
                      ))}
                    </select>
                    <input
                      placeholder="값 (예: I21.9, 급성 심근경색증)"
                      value={df.value}
                      onChange={(e) => {
                        const val = e.target.value;
                        setDirectFacts((prev) =>
                          prev.map((r, i) => (i === idx ? { ...r, value: val } : r))
                        );
                      }}
                    />
                    <button
                      type="button"
                      className="reject"
                      onClick={() => handleRemoveDirectFact(idx)}
                      style={{ padding: "4px 8px", fontSize: "12px" }}
                    >
                      삭제
                    </button>
                  </div>
                ))}
                <button
                  type="button"
                  className="secondary"
                  onClick={handleAddDirectFact}
                  style={{ fontSize: "12px" }}
                >
                  + 팩트 추가
                </button>
              </div>
            )}
          </div>
        </section>

        {/* Step 5: Automation Options */}
        <section className="card">
          <h2>5. 자동화 및 사정 착수 옵션</h2>
          <div style={{ display: "grid", gap: "8px", marginBottom: "14px" }}>
            <label style={{ display: "flex", alignItems: "center", gap: "8px", cursor: "pointer" }}>
              <input
                type="checkbox"
                checked={autoAnalyze}
                onChange={(e) => setAutoAnalyze(e.target.checked)}
              />
              <strong>접수 즉시 OCR 문서 분석 및 팩트 자동 추출</strong>
            </label>
            <label style={{ display: "flex", alignItems: "center", gap: "8px", cursor: "pointer" }}>
              <input
                type="checkbox"
                checked={autoConfirmFacts}
                onChange={(e) => setAutoConfirmFacts(e.target.checked)}
              />
              <strong>추출된 팩트 전문가 자동 확정 (EXPERT_CONFIRMED)</strong>
            </label>
            <label style={{ display: "flex", alignItems: "center", gap: "8px", cursor: "pointer" }}>
              <input
                type="checkbox"
                checked={autoAssess}
                onChange={(e) => setAutoAssess(e.target.checked)}
              />
              <strong>보장담보 해당성 평가 및 보험금 자동 계산 실행</strong>
            </label>
            <label style={{ display: "flex", alignItems: "center", gap: "8px", cursor: "pointer" }}>
              <input
                type="checkbox"
                checked={createReview}
                onChange={(e) => setCreateReview(e.target.checked)}
              />
              <strong>담당 손해사정사 심사 Review 자동 생성 및 즉시 배정 (본인)</strong>
            </label>
          </div>

          <label>
            사정 착수 사유
            <input
              value={reviewReason}
              onChange={(e) => setReviewReason(e.target.value)}
              placeholder="착수 사유를 입력하세요."
            />
          </label>
        </section>

        {/* Submit Button */}
        <div style={{ display: "flex", gap: "12px", alignItems: "center", marginTop: "12px" }}>
          <button
            type="submit"
            disabled={submitting}
            style={{
              padding: "14px 28px",
              fontSize: "16px",
              fontWeight: "bold",
              background: submitting ? "#98a2b3" : "#155eef",
            }}
          >
            {submitting ? "사정 처리 중..." : "🚀 원스톱 접수 및 사정 착수"}
          </button>
        </div>
      </form>
    </main>
  );
}
