"use client";

import Link from "next/link";
import { useParams } from "next/navigation";
import { useEffect, useState } from "react";
import { AdjusterProfileSettings, SETTINGS_STORAGE_KEY } from "../../../settings/page";

const api = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000";

interface AdjusterInfo {
  name: string;
  license_number: string;
  office_name: string;
  contact: string;
}

interface InsuredInfo {
  name: string;
  birth_date: string;
  gender: string;
  relationship_type: string;
  identity_masked: string;
}

interface ContractInfo {
  company_name: string;
  product_name: string;
  product_code: string;
  policy_number: string;
  contract_date: string | null;
  coverage_period: string | null;
  contract_status: string;
}

interface IncidentInfo {
  claim_type: string;
  accident_date: string | null;
  diagnosis_date: string | null;
  onset_date: string | null;
  location: string | null;
  description: string | null;
}

interface MedicalFact {
  fact_id: string;
  fact_type: string;
  label: string;
  fact_value: string;
}

interface CoverageItem {
  contract_coverage_id: string;
  coverage_name: string;
  insured_amount: number;
  eligibility_result: string;
  reason_summary: string;
  article_number: string | null;
  article_title: string | null;
  clause_text: string | null;
  calculation_status: string;
  payment_rate: string;
  final_amount: number;
  formula: string | null;
}

interface DocumentItem {
  document_id: string;
  document_type: string;
  document_type_label: string;
  original_filename: string;
  created_at: string;
}

interface ReviewInfo {
  review_id: string;
  review_status: string;
  review_type: string;
  reason: string;
  opinion: string | null;
  completed_at: string | null;
}

interface ReportData {
  report_id: string;
  report_number: string;
  claim_id: string;
  claim_number: string;
  created_at: string;
  adjuster: AdjusterInfo;
  insured: InsuredInfo;
  contract: ContractInfo;
  incident: IncidentInfo;
  medical_facts: MedicalFact[];
  coverages: CoverageItem[];
  total_assessed_amount: number;
  total_assessed_amount_korean: string;
  review: ReviewInfo | null;
  documents: DocumentItem[];
}

export default function LossAssessmentReportPage() {
  const { reviewId } = useParams<{ reviewId: string }>();
  const [report, setReport] = useState<ReportData | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  const [showStamp, setShowStamp] = useState(true);
  const [showWatermark, setShowWatermark] = useState(false);
  const [stampType, setStampType] = useState<"circular" | "oval" | "custom">("circular");
  const [customStampImage, setCustomStampImage] = useState("");
  const [stampRotation, setStampRotation] = useState(-8);
  const [noticeStatement, setNoticeStatement] = useState("");

  const [editAdjuster, setEditAdjuster] = useState(false);
  const [adjusterName, setAdjusterName] = useState("");
  const [adjusterLicense, setAdjusterLicense] = useState("");
  const [adjusterOffice, setAdjusterOffice] = useState("");
  const [adjusterContact, setAdjusterContact] = useState("");
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    async function load() {
      try {
        setLoading(true);
        const res = await fetch(`${api}/api/reviews/${reviewId}/report`, {
          credentials: "include",
        });
        if (!res.ok) {
          throw new Error("손해사정보고서 데이터를 불러올 수 없습니다.");
        }
        const data: ReportData = await res.json();
        setReport(data);

        // Load saved adjuster settings from localStorage if configured
        let appliedSettings: Partial<AdjusterProfileSettings> = {};
        try {
          const raw = localStorage.getItem(SETTINGS_STORAGE_KEY);
          if (raw) appliedSettings = JSON.parse(raw);
        } catch {
          // Ignore parse errors
        }

        setAdjusterName(appliedSettings.name || data.adjuster.name);
        setAdjusterLicense(appliedSettings.license || data.adjuster.license_number);
        setAdjusterOffice(appliedSettings.office || data.adjuster.office_name);
        setAdjusterContact(appliedSettings.contact || data.adjuster.contact);
        if (appliedSettings.stampType) setStampType(appliedSettings.stampType);
        if (appliedSettings.customStampImage) setCustomStampImage(appliedSettings.customStampImage);
        if (typeof appliedSettings.stampRotation === "number") setStampRotation(appliedSettings.stampRotation);
        if (typeof appliedSettings.showStampByDefault === "boolean") setShowStamp(appliedSettings.showStampByDefault);
        if (typeof appliedSettings.showWatermarkByDefault === "boolean") setShowWatermark(appliedSettings.showWatermarkByDefault);
        if (appliedSettings.noticeStatement) setNoticeStatement(appliedSettings.noticeStatement);
      } catch (err: unknown) {
        setError(err instanceof Error ? err.message : "오류가 발생했습니다.");
      } finally {
        setLoading(false);
      }
    }
    void load();
  }, [reviewId]);

  function handlePrint() {
    window.print();
  }

  async function handleCopy() {
    if (!report) return;
    const text = `
[손해사정서 (Loss Assessment Report)]
문서번호: ${report.report_number}
작성일자: ${new Date().toLocaleDateString("ko-KR")}

1. 사정 대상 및 당사자
- 피보험자: ${report.insured.name} (${report.insured.birth_date}, ${report.insured.gender})
- 보험회사: ${report.contract.company_name} / 상품명: ${report.contract.product_name}
- 증권번호: ${report.contract.policy_number} / 보험기간: ${report.contract.coverage_period ?? "-"}

2. 사고 및 진단 경위
- 사고/진단일: ${report.incident.diagnosis_date ?? report.incident.accident_date ?? "-"}
- 의료기관: ${report.incident.location ?? "-"}
- 사고내용: ${report.incident.description ?? "-"}

3. 손해액 및 사정 명세
${report.coverages
  .map(
    (c, i) =>
      `(${i + 1}) ${c.coverage_name}: 가입금액 ${c.insured_amount.toLocaleString("ko-KR")}원 / 사정금액: ${c.final_amount.toLocaleString("ko-KR")}원 (${c.eligibility_result})`
  )
  .join("\n")}

총 사정금액: ${report.total_assessed_amount_korean} (₩${report.total_assessed_amount.toLocaleString("ko-KR")})

4. 손해사정사 종합 의견
${report.review?.opinion ?? "약관 및 제출된 의무기록에 근거하여 사정을 종결함."}

손해사정사: ${adjusterName} (${adjusterLicense})
소속: ${adjusterOffice}
    `.trim();

    await navigator.clipboard.writeText(text);
    setCopied(true);
    setTimeout(() => setCopied(false), 2500);
  }

  if (loading) {
    return (
      <main style={{ padding: "40px", textAlign: "center" }}>
        <p>손해사정보고서를 생성하는 중입니다…</p>
      </main>
    );
  }

  if (error || !report) {
    return (
      <main style={{ padding: "40px" }}>
        <p className="error">{error || "보고서를 불러올 수 없습니다."}</p>
        <Link href={`/reviews/${reviewId}`}>← 검토 상세로 돌아가기</Link>
      </main>
    );
  }

  const currentDateStr = new Date().toLocaleDateString("ko-KR", {
    year: "numeric",
    month: "long",
    day: "numeric",
  });

  return (
    <main style={{ padding: "20px 40px", maxWidth: "960px", margin: "0 auto" }}>
      {/* 1. Non-printable Action Controls */}
      <div
        className="no-print"
        style={{
          display: "flex",
          justifyContent: "space-between",
          alignItems: "center",
          marginBottom: "20px",
          padding: "16px 20px",
          background: "#ffffff",
          borderRadius: "10px",
          boxShadow: "0 2px 8px rgba(0,0,0,0.06)",
        }}
      >
        <div style={{ display: "flex", gap: "10px", alignItems: "center" }}>
          <Link
            href={`/reviews/${reviewId}`}
            style={{
              padding: "8px 14px",
              background: "#475467",
              color: "white",
              borderRadius: "6px",
              textDecoration: "none",
              fontSize: "14px",
            }}
          >
            ← 검토 상세
          </Link>
          <span style={{ fontWeight: "bold", fontSize: "16px", color: "#101828" }}>
            손해사정보고서 미리보기
          </span>
          <span className="badge approved">{report.review?.review_status ?? "REPORT_READY"}</span>
        </div>

        <div style={{ display: "flex", gap: "8px", alignItems: "center" }}>
          <button
            onClick={() => setEditAdjuster(!editAdjuster)}
            style={{ background: "#344054", fontSize: "13px", padding: "8px 12px" }}
          >
            {editAdjuster ? "패널 닫기" : "사정사 정보 수정"}
          </button>
          <button
            onClick={() => setShowStamp(!showStamp)}
            style={{ background: "#344054", fontSize: "13px", padding: "8px 12px" }}
          >
            {showStamp ? "직인 숨김" : "직인 표시"}
          </button>
          <button
            onClick={() => setShowWatermark(!showWatermark)}
            style={{ background: showWatermark ? "#b54708" : "#344054", fontSize: "13px", padding: "8px 12px" }}
          >
            {showWatermark ? "초안 워터마크 ON" : "초안 워터마크 OFF"}
          </button>
          <Link
            href="/settings"
            style={{
              padding: "8px 12px",
              background: "#475467",
              color: "white",
              borderRadius: "6px",
              textDecoration: "none",
              fontSize: "13px",
            }}
          >
            ⚙️ 사정사 설정
          </Link>
          <button
            onClick={() => void handleCopy()}
            style={{ background: "#027a48", fontSize: "13px", padding: "8px 14px" }}
          >
            {copied ? "✓ 복사 완료!" : "📋 텍스트 복사"}
          </button>
          <button
            onClick={handlePrint}
            style={{
              background: "#155eef",
              fontSize: "14px",
              padding: "8px 18px",
              fontWeight: "bold",
            }}
          >
            🖨️ 보고서 인쇄 / PDF 저장
          </button>
        </div>
      </div>

      {/* Adjuster edit panel (screen only) */}
      {editAdjuster && (
        <section
          className="no-print card"
          style={{
            marginBottom: "20px",
            background: "#f8fafc",
            border: "1px dashed #64748b",
            padding: "16px 20px",
          }}
        >
          <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: "12px" }}>
            <h4 style={{ margin: 0 }}>손해사정사 표기 정보 (인쇄용 실시간 수정)</h4>
            <div style={{ display: "flex", gap: "8px" }}>
              <button
                type="button"
                onClick={() => {
                  try {
                    const profile: AdjusterProfileSettings = {
                      name: adjusterName,
                      license: adjusterLicense,
                      office: adjusterOffice,
                      contact: adjusterContact,
                      stampType,
                      customStampImage,
                      stampRotation,
                      showStampByDefault: showStamp,
                      showWatermarkByDefault: showWatermark,
                      noticeStatement,
                    };
                    localStorage.setItem(SETTINGS_STORAGE_KEY, JSON.stringify(profile));
                    alert("✓ 현재 사정사 정보가 모든 보고서 기본값으로 저장되었습니다.");
                  } catch {
                    alert("저장 중 오류가 발생했습니다.");
                  }
                }}
                style={{ background: "#067647", fontSize: "12px", padding: "6px 12px" }}
              >
                💾 이 정보를 기본값으로 저장
              </button>
            </div>
          </div>
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: "12px" }}>
            <label style={{ fontSize: "13px" }}>
              사정사 성명
              <input
                type="text"
                value={adjusterName}
                onChange={(e) => setAdjusterName(e.target.value)}
              />
            </label>
            <label style={{ fontSize: "13px" }}>
              자격 / 등록번호
              <input
                type="text"
                value={adjusterLicense}
                onChange={(e) => setAdjusterLicense(e.target.value)}
              />
            </label>
            <label style={{ fontSize: "13px" }}>
              소속 사무소명
              <input
                type="text"
                value={adjusterOffice}
                onChange={(e) => setAdjusterOffice(e.target.value)}
              />
            </label>
            <label style={{ fontSize: "13px" }}>
              연락처 / 이메일
              <input
                type="text"
                value={adjusterContact}
                onChange={(e) => setAdjusterContact(e.target.value)}
              />
            </label>
          </div>
        </section>
      )}

      {/* 2. Official Loss Assessment Report Document Body (A4 Style) */}
      <article
        id="loss-assessment-document"
        style={{
          position: "relative",
          overflow: "hidden",
          background: "#ffffff",
          color: "#111827",
          padding: "50px 60px",
          borderRadius: "4px",
          boxShadow: "0 4px 20px rgba(0,0,0,0.08)",
          fontFamily: "'Nanum Myeongjo', 'Batang', serif, -apple-system, BlinkMacSystemFont",
          lineHeight: "1.6",
        }}
      >
        {/* Optional DRAFT Watermark */}
        {showWatermark && (
          <div
            style={{
              position: "absolute",
              top: "45%",
              left: "50%",
              transform: "translate(-50%, -50%) rotate(-30deg)",
              fontSize: "84px",
              fontWeight: 900,
              color: "rgba(220, 38, 38, 0.07)",
              letterSpacing: "14px",
              pointerEvents: "none",
              userSelect: "none",
              zIndex: 0,
              whiteSpace: "nowrap",
            }}
          >
            초안 (DRAFT)
          </div>
        )}

        {/* Document Header */}
        <header style={{ position: "relative", zIndex: 1, textAlign: "center", marginBottom: "36px", borderBottom: "2px solid #111827", paddingBottom: "20px" }}>
          <h1
            style={{
              fontSize: "30px",
              fontWeight: "900",
              letterSpacing: "12px",
              margin: "0 0 14px 0",
              fontFamily: "'Batang', serif",
            }}
          >
            손 해 사 정 서
          </h1>
          <p style={{ margin: 0, fontSize: "13px", color: "#6b7280", letterSpacing: "2px" }}>
            LOSS ASSESSMENT REPORT
          </p>
          <div
            style={{
              display: "flex",
              justifyContent: "space-between",
              marginTop: "20px",
              fontSize: "13px",
              color: "#374151",
            }}
          >
            <span>문서번호: <strong>{report.report_number}</strong></span>
            <span>작성일자: {currentDateStr}</span>
            <span>구분: 일반/질병보험 손해사정</span>
          </div>
        </header>

        {/* Section 1: Parties and Policy Info */}
        <section style={{ marginBottom: "28px" }}>
          <h3
            style={{
              fontSize: "16px",
              fontWeight: "bold",
              borderLeft: "4px solid #1f2937",
              paddingLeft: "8px",
              margin: "0 0 10px 0",
            }}
          >
            1. 사정 대상 및 당사자 인적사항
          </h3>
          <table
            style={{
              width: "100%",
              borderCollapse: "collapse",
              fontSize: "13px",
              border: "1px solid #9ca3af",
            }}
          >
            <tbody>
              <tr>
                <th style={reportHeaderStyle}>피보험자</th>
                <td style={reportCellStyle}>{report.insured.name}</td>
                <th style={reportHeaderStyle}>생년월일 / 성별</th>
                <td style={reportCellStyle}>
                  {report.insured.birth_date} ({report.insured.gender === "MALE" ? "남" : report.insured.gender === "FEMALE" ? "여" : "-"})
                </td>
              </tr>
              <tr>
                <th style={reportHeaderStyle}>식별번호</th>
                <td style={reportCellStyle}>{report.insured.identity_masked}</td>
                <th style={reportHeaderStyle}>계약자와의 관계</th>
                <td style={reportCellStyle}>{report.insured.relationship_type}</td>
              </tr>
              <tr>
                <th style={reportHeaderStyle}>보험회사</th>
                <td style={reportCellStyle}>{report.contract.company_name}</td>
                <th style={reportHeaderStyle}>가입 상품명</th>
                <td style={reportCellStyle}>
                  {report.contract.product_name} ({report.contract.product_code})
                </td>
              </tr>
              <tr>
                <th style={reportHeaderStyle}>증권번호</th>
                <td style={reportCellStyle}>{report.contract.policy_number}</td>
                <th style={reportHeaderStyle}>보험기간</th>
                <td style={reportCellStyle}>{report.contract.coverage_period ?? "-"}</td>
              </tr>
            </tbody>
          </table>
        </section>

        {/* Section 2: Accident & Medical Facts */}
        <section style={{ marginBottom: "28px" }}>
          <h3
            style={{
              fontSize: "16px",
              fontWeight: "bold",
              borderLeft: "4px solid #1f2937",
              paddingLeft: "8px",
              margin: "0 0 10px 0",
            }}
          >
            2. 사고 및 진단 경위 (확인된 사실관계)
          </h3>
          <table
            style={{
              width: "100%",
              borderCollapse: "collapse",
              fontSize: "13px",
              border: "1px solid #9ca3af",
              marginBottom: "10px",
            }}
          >
            <tbody>
              <tr>
                <th style={reportHeaderStyle}>사고 / 진단일자</th>
                <td style={reportCellStyle}>
                  {report.incident.diagnosis_date ?? report.incident.accident_date ?? "-"}
                </td>
                <th style={reportHeaderStyle}>의료기관 / 장소</th>
                <td style={reportCellStyle}>{report.incident.location ?? "진단서 기재 의료기관"}</td>
              </tr>
              <tr>
                <th style={reportHeaderStyle}>사고 / 발병 경위</th>
                <td style={reportCellStyle} colSpan={3}>
                  {report.incident.description ?? "피보험자 진술 및 제출된 의무기록에 부합함."}
                </td>
              </tr>
            </tbody>
          </table>

          {report.medical_facts.length > 0 && (
            <div style={{ background: "#f9fafb", padding: "12px", border: "1px solid #e5e7eb", borderRadius: "4px", fontSize: "12.5px" }}>
              <strong style={{ display: "block", marginBottom: "6px", color: "#374151" }}>[의무기록 Fact 검증 내역]</strong>
              <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(220px, 1fr))", gap: "6px 16px" }}>
                {report.medical_facts.map((fact) => (
                  <div key={fact.fact_id}>
                    <span style={{ color: "#6b7280" }}>• {fact.label}: </span>
                    <strong>{fact.fact_value}</strong>
                  </div>
                ))}
              </div>
            </div>
          )}
        </section>

        {/* Section 3: Applicable Policy Clauses */}
        <section style={{ marginBottom: "28px" }}>
          <h3
            style={{
              fontSize: "16px",
              fontWeight: "bold",
              borderLeft: "4px solid #1f2937",
              paddingLeft: "8px",
              margin: "0 0 10px 0",
            }}
          >
            3. 적용 약관 조항 및 보상책임 검토
          </h3>
          <table
            style={{
              width: "100%",
              borderCollapse: "collapse",
              fontSize: "13px",
              border: "1px solid #9ca3af",
            }}
          >
            <thead>
              <tr style={{ background: "#f3f4f6" }}>
                <th style={{ ...reportHeaderStyle, textAlign: "center", width: "25%" }}>담보명</th>
                <th style={{ ...reportHeaderStyle, textAlign: "center", width: "25%" }}>적용 약관 조문</th>
                <th style={{ ...reportHeaderStyle, textAlign: "center", width: "50%" }}>약관 내용 및 검토 소견</th>
              </tr>
            </thead>
            <tbody>
              {report.coverages.map((cov) => (
                <tr key={cov.contract_coverage_id}>
                  <td style={{ ...reportCellStyle, fontWeight: "bold" }}>{cov.coverage_name}</td>
                  <td style={reportCellStyle}>
                    {cov.article_number ?? "보장특약"} {cov.article_title ? `(${cov.article_title})` : ""}
                  </td>
                  <td style={reportCellStyle}>
                    {cov.clause_text && (
                      <p style={{ margin: "0 0 4px 0", color: "#4b5563", fontSize: "12px" }}>
                        &quot;{cov.clause_text.length > 90 ? `${cov.clause_text.slice(0, 90)}…` : cov.clause_text}&quot;
                      </p>
                    )}
                    <span style={{ color: cov.eligibility_result === "PAYABLE" ? "#027a48" : "#b42318", fontWeight: "bold" }}>
                      [판정결과] {cov.eligibility_result} - {cov.reason_summary}
                    </span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>

        {/* Section 4: Calculation Breakdown */}
        <section style={{ marginBottom: "28px" }}>
          <h3
            style={{
              fontSize: "16px",
              fontWeight: "bold",
              borderLeft: "4px solid #1f2937",
              paddingLeft: "8px",
              margin: "0 0 10px 0",
            }}
          >
            4. 손해액 및 지급예정 보험금 사정 명세
          </h3>
          <table
            style={{
              width: "100%",
              borderCollapse: "collapse",
              fontSize: "13px",
              border: "1px solid #9ca3af",
            }}
          >
            <thead>
              <tr style={{ background: "#f3f4f6" }}>
                <th style={{ ...reportHeaderStyle, textAlign: "center" }}>담보명</th>
                <th style={{ ...reportHeaderStyle, textAlign: "right" }}>가입금액</th>
                <th style={{ ...reportHeaderStyle, textAlign: "center" }}>지급률(요건)</th>
                <th style={{ ...reportHeaderStyle, textAlign: "right" }}>사정금액</th>
                <th style={{ ...reportHeaderStyle, textAlign: "center" }}>산출공식</th>
              </tr>
            </thead>
            <tbody>
              {report.coverages.map((cov) => (
                <tr key={cov.contract_coverage_id}>
                  <td style={reportCellStyle}>{cov.coverage_name}</td>
                  <td style={{ ...reportCellStyle, textAlign: "right" }}>
                    {cov.insured_amount.toLocaleString("ko-KR")}원
                  </td>
                  <td style={{ ...reportCellStyle, textAlign: "center" }}>
                    {cov.payment_rate} ({cov.eligibility_result})
                  </td>
                  <td style={{ ...reportCellStyle, textAlign: "right", fontWeight: "bold" }}>
                    {cov.final_amount.toLocaleString("ko-KR")}원
                  </td>
                  <td style={{ ...reportCellStyle, textAlign: "center", fontSize: "12px", color: "#4b5563" }}>
                    {cov.formula ?? "-"}
                  </td>
                </tr>
              ))}
            </tbody>
            <tfoot>
              <tr style={{ background: "#f9fafb", fontWeight: "bold" }}>
                <td style={{ ...reportCellStyle, textAlign: "center" }} colSpan={3}>
                  합 계 사 정 금 액
                </td>
                <td style={{ ...reportCellStyle, textAlign: "right", fontSize: "14px", color: "#1e40af" }} colSpan={2}>
                  {report.total_assessed_amount.toLocaleString("ko-KR")}원
                </td>
              </tr>
            </tfoot>
          </table>

          {/* Grand Total Highlight Box */}
          <div
            style={{
              marginTop: "12px",
              padding: "12px 18px",
              background: "#eff6ff",
              border: "2px solid #bfdbfe",
              borderRadius: "4px",
              display: "flex",
              justifyContent: "space-between",
              alignItems: "center",
            }}
          >
            <span style={{ fontSize: "14px", fontWeight: "bold", color: "#1e3a8a" }}>
              총 사정결정금액
            </span>
            <span style={{ fontSize: "17px", fontWeight: "900", color: "#1d4ed8" }}>
              {report.total_assessed_amount_korean} (₩{report.total_assessed_amount.toLocaleString("ko-KR")})
            </span>
          </div>
        </section>

        {/* Section 5: Adjuster Opinion */}
        <section style={{ marginBottom: "28px" }}>
          <h3
            style={{
              fontSize: "16px",
              fontWeight: "bold",
              borderLeft: "4px solid #1f2937",
              paddingLeft: "8px",
              margin: "0 0 10px 0",
            }}
          >
            5. 손해사정사 종합 의견
          </h3>
          <div
            style={{
              border: "1px solid #9ca3af",
              padding: "16px 20px",
              background: "#ffffff",
              fontSize: "13.5px",
              lineHeight: "1.8",
              whiteSpace: "pre-wrap",
            }}
          >
            {report.review?.opinion ? (
              report.review.opinion
            ) : (
              `1. 계약 전 알릴의무(고지의무) 위반 여부 검토:
피보험자의 보험가입일 이후 발생한 질병/사고 건으로, 청약서상 고지 누락이나 기왕증 관련 면책 사유는 확인되지 않음.

2. 담보 해당성 및 약관 지급요건 검토:
제출된 진단서 및 의무기록을 검토한 결과, 해당 보험약관의 보상하는 손해 조항(면책기간 경과 및 확정진단)에 정확히 부합함.

3. 종합 사정 결론:
상기 약관 조항 및 증빙자료에 근거하여 상기 사정명세표와 같이 보험금 전액 지급이 타당한 것으로 사정함.`
            )}
          </div>
        </section>

        {/* Section 6: Attached Documents */}
        {report.documents.length > 0 && (
          <section style={{ marginBottom: "36px" }}>
            <h3
              style={{
                fontSize: "16px",
                fontWeight: "bold",
                borderLeft: "4px solid #1f2937",
                paddingLeft: "8px",
                margin: "0 0 10px 0",
              }}
            >
              6. 첨부 입증 서류 목록
            </h3>
            <table
              style={{
                width: "100%",
                borderCollapse: "collapse",
                fontSize: "12.5px",
                border: "1px solid #9ca3af",
              }}
            >
              <thead>
                <tr style={{ background: "#f3f4f6" }}>
                  <th style={{ ...reportHeaderStyle, width: "30%" }}>서류 구분</th>
                  <th style={reportHeaderStyle}>파일명</th>
                  <th style={{ ...reportHeaderStyle, width: "25%", textAlign: "center" }}>접수일시</th>
                </tr>
              </thead>
              <tbody>
                {report.documents.map((doc) => (
                  <tr key={doc.document_id}>
                    <td style={reportCellStyle}>{doc.document_type_label}</td>
                    <td style={reportCellStyle}>{doc.original_filename}</td>
                    <td style={{ ...reportCellStyle, textAlign: "center" }}>
                      {new Date(doc.created_at).toLocaleDateString("ko-KR")}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </section>
        )}

        {/* Footer & Signature Block */}
        <footer
          style={{
            marginTop: "40px",
            paddingTop: "24px",
            borderTop: "2px solid #111827",
            textAlign: "center",
            pageBreakInside: "avoid",
          }}
        >
          <p style={{ fontSize: "14px", fontWeight: "bold", margin: "0 0 16px 0", color: "#374151", whiteSpace: "pre-line" }}>
            {noticeStatement || (
              <>
                위와 같이 보험업법 제185조 및 해당 보험약관에 의하여 공정하고 객관적으로
                <br />
                손해사정을 수행하고 본 손해사정서를 작성·교부합니다.
              </>
            )}
          </p>

          <p style={{ fontSize: "14px", margin: "0 0 24px 0", color: "#111827" }}>
            {currentDateStr}
          </p>

          <div
            style={{
              display: "flex",
              justifyContent: "center",
              alignItems: "center",
              gap: "24px",
              marginTop: "16px",
            }}
          >
            <div style={{ textAlign: "right", fontSize: "14px", lineHeight: "1.8" }}>
              <div>소 속: <strong>{adjusterOffice}</strong></div>
              <div>자 격: <strong>{adjusterLicense}</strong></div>
              <div>
                손해사정사: <strong style={{ fontSize: "16px", letterSpacing: "2px" }}>{adjusterName}</strong>
              </div>
            </div>

            {/* Official Seal / Stamp */}
            {showStamp && (
              stampType === "custom" && customStampImage ? (
                <div
                  style={{
                    width: "72px",
                    height: "72px",
                    display: "flex",
                    alignItems: "center",
                    justifyContent: "center",
                    transform: `rotate(${stampRotation}deg)`,
                  }}
                >
                  {/* eslint-disable-next-line @next/next/no-img-element */}
                  <img
                    src={customStampImage}
                    alt="손해사정사 직인"
                    style={{ maxWidth: "72px", maxHeight: "72px", objectFit: "contain" }}
                  />
                </div>
              ) : stampType === "oval" ? (
                <div
                  style={{
                    width: "80px",
                    height: "56px",
                    border: "3px solid #dc2626",
                    borderRadius: "50%",
                    display: "flex",
                    flexDirection: "column",
                    justifyContent: "center",
                    alignItems: "center",
                    color: "#dc2626",
                    fontSize: "11px",
                    fontWeight: "bold",
                    lineHeight: "1.2",
                    transform: `rotate(${stampRotation}deg)`,
                    boxShadow: "inset 0 0 3px rgba(220, 38, 38, 0.25)",
                    userSelect: "none",
                  }}
                >
                  <span style={{ fontSize: "9px" }}>손해사정사</span>
                  <span style={{ fontSize: "13px", letterSpacing: "1px" }}>{adjusterName.slice(0, 3) || "손사"}</span>
                  <span style={{ fontSize: "9px" }}>[인]</span>
                </div>
              ) : (
                <div
                  style={{
                    width: "72px",
                    height: "72px",
                    border: "3px solid #dc2626",
                    borderRadius: "50%",
                    display: "flex",
                    flexDirection: "column",
                    justifyContent: "center",
                    alignItems: "center",
                    color: "#dc2626",
                    fontSize: "11px",
                    fontWeight: "bold",
                    lineHeight: "1.2",
                    transform: `rotate(${stampRotation}deg)`,
                    boxShadow: "inset 0 0 4px rgba(220, 38, 38, 0.2)",
                    userSelect: "none",
                  }}
                >
                  <span>손해</span>
                  <span style={{ fontSize: "13px", letterSpacing: "1px" }}>{adjusterName.slice(0, 3) || "사정사"}</span>
                  <span>[인]</span>
                </div>
              )
            )}
          </div>
        </footer>
      </article>
    </main>
  );
}

const reportHeaderStyle: React.CSSProperties = {
  padding: "8px 12px",
  background: "#f3f4f6",
  border: "1px solid #9ca3af",
  color: "#1f2937",
  fontWeight: "bold",
  fontSize: "12.5px",
};

const reportCellStyle: React.CSSProperties = {
  padding: "8px 12px",
  border: "1px solid #9ca3af",
  fontSize: "13px",
  color: "#111827",
};
