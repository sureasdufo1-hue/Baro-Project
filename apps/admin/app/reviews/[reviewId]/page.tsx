"use client";

/* eslint-disable react-hooks/set-state-in-effect */
/* eslint-disable react-hooks/exhaustive-deps */
import Link from "next/link";
import { useParams } from "next/navigation";
import { useEffect, useState } from "react";

const api = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000";
const web = process.env.NEXT_PUBLIC_WEB_URL ?? "http://localhost:3000";

interface Review {
  claim_id: string;
  review_type: string;
  review_status: string;
  reason: string;
  opinion: string | null;
  previous_result: Record<string, unknown>;
}

interface ReportContext {
  claim_number: string;
  total_assessed_amount: number;
  total_assessed_amount_korean: string;
  insured: { name: string; birth_date: string; gender: string };
  contract: {
    company_name: string;
    product_name: string;
    policy_number: string;
    contract_date: string | null;
  };
  incident: {
    accident_date: string | null;
    diagnosis_date: string | null;
    location: string | null;
    description: string | null;
  };
  medical_facts: Array<{ fact_id: string; fact_type: string; label: string; fact_value: string }>;
  coverages: Array<{
    coverage_name: string;
    article_number: string | null;
    article_title: string | null;
    insured_amount: number;
    final_amount: number;
    eligibility_result: string;
  }>;
}

export default function ReviewDetail() {
  const { reviewId } = useParams<{ reviewId: string }>();
  const [item, setItem] = useState<Review | null>(null);
  const [report, setReport] = useState<ReportContext | null>(null);

  const [opinion, setOpinion] = useState("");
  const [disclosureText, setDisclosureText] = useState("");
  const [medicalText, setMedicalText] = useState("");
  const [conclusionText, setConclusionText] = useState("");

  const [reason, setReason] = useState("");
  const [finalEligibility, setFinalEligibility] = useState("PAYABLE");
  const [message, setMessage] = useState("");
  const [activeTab, setActiveTab] = useState<"workspace" | "raw">("workspace");

  async function load() {
    const r = await fetch(`${api}/api/reviews/${reviewId}`, { credentials: "include" });
    if (r.ok) {
      const data: Review = await r.json();
      setItem(data);
      if (data.opinion && !opinion) {
        setOpinion(data.opinion);
      }
    }

    const rep = await fetch(`${api}/api/reviews/${reviewId}/report`, { credentials: "include" });
    if (rep.ok) {
      const repData: ReportContext = await rep.json();
      setReport(repData);
    }
  }

  useEffect(() => {
    void load();
  }, [reviewId]);

  async function action(name: string, body: object = {}) {
    const r = await fetch(`${api}/api/reviews/${reviewId}/${name}`, {
      method: "POST",
      credentials: "include",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    setMessage(r.ok ? "성공적으로 처리되었습니다." : "상태와 필수 입력을 확인하세요.");
    await load();
  }

  // Quick fill helpers
  function fillDisclosure() {
    const cDate = report?.contract.contract_date ?? "가입일";
    const text = `계약 체결일(${cDate}) 기준 3개월/1년/5년 이내 상법 제651조 및 당해 약관상 고지 대상에 해당하는 치료력 및 기왕증은 확인되지 아니함. 따라서 계약 전 알릴의무 위반에 따른 해지 또는 면책 사유는 존재하지 아니함.`;
    setDisclosureText(text);
  }

  function fillMedical() {
    const diagCodes =
      report?.medical_facts
        .filter((f) => f.fact_type === "DIAGNOSIS_CODE")
        .map((f) => f.fact_value)
        .join(", ") || "확정진단";
    const diagNames =
      report?.medical_facts
        .filter((f) => f.fact_type === "DIAGNOSIS_NAME")
        .map((f) => f.fact_value)
        .join(", ") || "진단명";
    const clauses =
      report?.coverages
        .map((c) => `${c.coverage_name}(${c.article_number ?? "보장특약"})`)
        .join(", ") || "약관 규정";

    const text = `제출된 진단서 및 의무기록 검토 결과, 피보험자는 KCD 코드 ${diagCodes}(${diagNames})에 부합함. 당해 보험약관 ${clauses}에서 정한 보상하는 손해 요건(면책기간 경과, 정밀검사 확정진단)을 충족하여 보험금 지급 요건에 해당함.`;
    setMedicalText(text);
  }

  function fillConclusion() {
    const totalKorean = report?.total_assessed_amount_korean ?? "산정금액";
    const totalNum = report?.total_assessed_amount?.toLocaleString("ko-KR") ?? "0";
    const text = `상기 사실관계, 약관 조항 및 의학적 소견 검토 결과에 의거하여, 피보험자에게 총 사정금액인 ${totalKorean} (₩${totalNum})을 전액 지급하는 것이 타당한 것으로 최종 사정함.`;
    setConclusionText(text);
  }

  function synthesizeOpinion() {
    const part1 = disclosureText.trim() || "계약 전 알릴의무 위반 및 면책 사유 확인되지 아니함.";
    const part2 = medicalText.trim() || "약관상 보상하는 손해 요건을 정확히 충족함.";
    const part3 = conclusionText.trim() || "정상 지급 권고함.";

    const combined = `1. 계약 전 알릴의무(고지의무) 위반 여부 검토:
${part1}

2. 담보 해당성 및 의학적 소견:
${part2}

3. 종합 사정 결론:
${part3}`;
    setOpinion(combined);
    setMessage("의견 문안이 종합 합성되었습니다. 저장 또는 승인을 진행하세요.");
  }

  if (!item) {
    return (
      <main style={{ padding: "40px" }}>
        <p>Review 데이터를 불러오는 중…</p>
      </main>
    );
  }

  return (
    <main style={{ maxWidth: "1000px" }}>
      {/* 1. Header Bar */}
      <div
        style={{
          display: "flex",
          justifyContent: "space-between",
          alignItems: "center",
          marginBottom: "20px",
        }}
      >
        <div>
          <h1 style={{ margin: "0 0 4px 0" }}>손해사정 심사 워크스페이스</h1>
          <p style={{ margin: 0, color: "#4b5563", fontSize: "14px" }}>
            사건번호: <strong>{report?.claim_number ?? item.claim_id}</strong> · {item.review_type}
          </p>
        </div>
        <div style={{ display: "flex", gap: "10px", alignItems: "center" }}>
          <span className="badge approved">{item.review_status}</span>
          <Link
            href={`/reviews/${reviewId}/report`}
            style={{
              padding: "8px 16px",
              background: "#027a48",
              color: "white",
              borderRadius: "6px",
              textDecoration: "none",
              fontWeight: "bold",
              fontSize: "14px",
              display: "inline-flex",
              alignItems: "center",
              gap: "6px",
            }}
          >
            📄 손해사정서 미리보기 / 인쇄
          </Link>
        </div>
      </div>

      {/* 2. Case Context Summary Banner */}
      {report && (
        <section
          className="card"
          style={{
            marginBottom: "16px",
            background: "#f0fdf4",
            border: "1px solid #bbf7d0",
            padding: "16px 20px",
          }}
        >
          <div
            style={{
              display: "grid",
              gridTemplateColumns: "repeat(auto-fit, minmax(200px, 1fr))",
              gap: "12px",
              fontSize: "13.5px",
            }}
          >
            <div>
              <span style={{ color: "#166534" }}>피보험자: </span>
              <strong>{report.insured.name}</strong> ({report.insured.birth_date})
            </div>
            <div>
              <span style={{ color: "#166534" }}>보험회사 / 상품: </span>
              <strong>{report.contract.company_name}</strong> · {report.contract.product_name}
            </div>
            <div>
              <span style={{ color: "#166534" }}>증권번호: </span>
              <strong>{report.contract.policy_number}</strong>
            </div>
            <div>
              <span style={{ color: "#166534" }}>사정결정금액: </span>
              <strong style={{ color: "#15803d", fontSize: "15px" }}>
                {report.total_assessed_amount_korean} (₩{report.total_assessed_amount.toLocaleString("ko-KR")})
              </strong>
            </div>
          </div>
        </section>
      )}

      {/* 3. Automatic Decision & Calculation Evidence Card */}
      <section className="card" style={{ marginBottom: "16px" }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
          <h2 style={{ margin: 0, fontSize: "16px" }}>자동 판단 및 계산 근거 (Evidence Chain)</h2>
          <a
            href={`${web}/claims/${item.claim_id}/result`}
            target="_blank"
            rel="noreferrer"
            style={{ fontSize: "13px", color: "#155eef" }}
          >
            전체 상세 열기 ↗
          </a>
        </div>
        <p style={{ margin: "8px 0", fontSize: "14px", color: "#374151" }}>{item.reason}</p>

        {report && report.coverages.length > 0 ? (
          <table style={{ marginTop: "10px", fontSize: "13px" }}>
            <thead>
              <tr style={{ background: "#f8fafc" }}>
                <th>담보명</th>
                <th>가입금액</th>
                <th>적용 약관 조항</th>
                <th>판정</th>
                <th>사정금액</th>
              </tr>
            </thead>
            <tbody>
              {report.coverages.map((cov, idx) => (
                <tr key={idx}>
                  <td style={{ fontWeight: "bold" }}>{cov.coverage_name}</td>
                  <td>{cov.insured_amount.toLocaleString("ko-KR")}원</td>
                  <td>{cov.article_number ?? "특약"} {cov.article_title ? `(${cov.article_title})` : ""}</td>
                  <td>
                    <span style={{ color: cov.eligibility_result === "PAYABLE" ? "#027a48" : "#b42318", fontWeight: "bold" }}>
                      {cov.eligibility_result}
                    </span>
                  </td>
                  <td style={{ fontWeight: "bold", color: "#1e40af" }}>
                    {cov.final_amount.toLocaleString("ko-KR")}원
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : (
          <pre style={{ fontSize: "12px", background: "#f8fafc", padding: "10px", borderRadius: "6px" }}>
            {JSON.stringify(item.previous_result, null, 2)}
          </pre>
        )}
      </section>

      {/* 4. Loss Assessment Report Opinion Workspace */}
      <section className="card" style={{ marginBottom: "16px" }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: "14px" }}>
          <div>
            <h2 style={{ margin: "0 0 2px 0", fontSize: "17px" }}>손해사정서 의견 작성 워크스페이스</h2>
            <p style={{ margin: 0, fontSize: "13px", color: "#6b7280" }}>
              작성된 의견은 공식 손해사정서의 [제5항 손해사정사 종합 의견]에 자동 반영됩니다.
            </p>
          </div>
          <div style={{ display: "flex", gap: "6px" }}>
            <button
              onClick={() => setActiveTab("workspace")}
              style={{
                background: activeTab === "workspace" ? "#155eef" : "#f1f5f9",
                color: activeTab === "workspace" ? "white" : "#475467",
                fontSize: "12.5px",
                padding: "6px 12px",
              }}
            >
              단계별 구조화 작성
            </button>
            <button
              onClick={() => setActiveTab("raw")}
              style={{
                background: activeTab === "raw" ? "#155eef" : "#f1f5f9",
                color: activeTab === "raw" ? "white" : "#475467",
                fontSize: "12.5px",
                padding: "6px 12px",
              }}
            >
              통합 문안 직접 편집
            </button>
          </div>
        </div>

        {activeTab === "workspace" ? (
          <div style={{ display: "grid", gap: "16px" }}>
            {/* Step 1: Disclosure Obligation */}
            <div style={{ background: "#f8fafc", padding: "14px", borderRadius: "8px", border: "1px solid #e2e8f0" }}>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: "6px" }}>
                <strong style={{ fontSize: "14px", color: "#1e293b" }}>1. 계약 전 알릴의무(고지의무) 검토 소견</strong>
                <button
                  type="button"
                  onClick={fillDisclosure}
                  style={{ background: "#475467", fontSize: "12px", padding: "4px 10px" }}
                >
                  기본 문구 자동 삽입
                </button>
              </div>
              <textarea
                placeholder="보험가입 전 병력 고지사항 누락 여부 및 상법 제651조 관련 검토 소견을 입력하세요..."
                value={disclosureText}
                onChange={(e) => setDisclosureText(e.target.value)}
                style={{ width: "100%", minHeight: "65px", fontSize: "13px" }}
              />
            </div>

            {/* Step 2: Medical Findings & Clauses */}
            <div style={{ background: "#f8fafc", padding: "14px", borderRadius: "8px", border: "1px solid #e2e8f0" }}>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: "6px" }}>
                <strong style={{ fontSize: "14px", color: "#1e293b" }}>2. 담보 해당성 및 의학적 소견 검토</strong>
                <button
                  type="button"
                  onClick={fillMedical}
                  style={{ background: "#475467", fontSize: "12px", padding: "4px 10px" }}
                >
                  팩트 & 약관 조문 자동 인용
                </button>
              </div>
              <textarea
                placeholder="KCD 질병코드, 조직검사/수술기록 및 약관상 보상하는 손해 조항 해당 여부를 입력하세요..."
                value={medicalText}
                onChange={(e) => setMedicalText(e.target.value)}
                style={{ width: "100%", minHeight: "65px", fontSize: "13px" }}
              />
            </div>

            {/* Step 3: Conclusion & Recommendation */}
            <div style={{ background: "#f8fafc", padding: "14px", borderRadius: "8px", border: "1px solid #e2e8f0" }}>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: "6px" }}>
                <strong style={{ fontSize: "14px", color: "#1e293b" }}>3. 종합 사정 결론 및 지급 권고</strong>
                <button
                  type="button"
                  onClick={fillConclusion}
                  style={{ background: "#475467", fontSize: "12px", padding: "4px 10px" }}
                >
                  사정결정금액 자동 삽입
                </button>
              </div>
              <textarea
                placeholder="최종 지급 권고 의견 및 사정결정금액 결론을 입력하세요..."
                value={conclusionText}
                onChange={(e) => setConclusionText(e.target.value)}
                style={{ width: "100%", minHeight: "65px", fontSize: "13px" }}
              />
            </div>

            {/* Synthesize Button */}
            <div style={{ display: "flex", gap: "10px", alignItems: "center" }}>
              <button
                type="button"
                onClick={synthesizeOpinion}
                style={{
                  background: "#155eef",
                  padding: "10px 18px",
                  fontWeight: "bold",
                  fontSize: "14px",
                }}
              >
                ✨ 전체 표준 의견 종합 합성
              </button>
              <span style={{ fontSize: "12.5px", color: "#6b7280" }}>
                (각 단계의 소견을 취합하여 손해사정서 본문 문안으로 완성합니다)
              </span>
            </div>
          </div>
        ) : null}

        {/* Combined Opinion Textarea */}
        <div style={{ marginTop: "16px" }}>
          <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: "6px" }}>
            <strong style={{ fontSize: "14px" }}>최종 손해사정의견 전문 (보고서 본문 반영)</strong>
            <button
              type="button"
              onClick={() => void action("opinion", { opinion })}
              style={{ background: "#344054", fontSize: "12px", padding: "5px 12px" }}
            >
              💾 의견 임시저장
            </button>
          </div>
          <textarea
            value={opinion}
            onChange={(e) => setOpinion(e.target.value)}
            style={{ width: "100%", minHeight: "140px", fontSize: "13.5px", lineHeight: "1.6" }}
            placeholder="상단의 [종합 합성] 버튼을 누르거나 직접 자유롭게 의견을 작성하세요..."
          />
        </div>
      </section>

      {/* 5. Adjuster Final Actions Card */}
      <section className="card">
        <h2 style={{ fontSize: "16px", margin: "0 0 12px 0" }}>심사 종결 및 승인 Action</h2>

        {item.review_status === "ASSIGNED" && (
          <button onClick={() => void action("accept")} style={{ padding: "10px 20px" }}>
            검토 시작 (Accept)
          </button>
        )}

        {item.review_status === "IN_PROGRESS" && (
          <div style={{ display: "grid", gap: "12px" }}>
            <div style={{ display: "flex", gap: "10px" }}>
              <button
                onClick={() => void action("approve", { opinion })}
                style={{ background: "#027a48", padding: "10px 22px", fontWeight: "bold" }}
              >
                ✓ 심사 승인 (Approve)
              </button>
              <button
                onClick={() => void action("undetermined", { reason, opinion })}
                style={{ background: "#475467", padding: "10px 18px" }}
              >
                판단불가 (Undetermined)
              </button>
            </div>

            {/* Request Additional Documents section */}
            <div style={{ marginTop: "12px", padding: "14px", background: "#f8fafc", borderRadius: "8px", border: "1px solid #e2e8f0" }}>
              <label style={{ fontSize: "13px", display: "block", marginBottom: "6px" }}>
                추가서류 요청 / 반려 사유:
                <input
                  type="text"
                  value={reason}
                  onChange={(e) => setReason(e.target.value)}
                  placeholder="예: 정확한 병리조직검사결과지 추가 제출 요망"
                  style={{ width: "100%", marginTop: "4px" }}
                />
              </label>
              <button
                onClick={() =>
                  void action("request-documents", {
                    reason: reason || "추가 증빙 서류 제출 요청",
                    user_message: reason || "손해사정을 위해 추가 의무기록을 제출해 주세요.",
                    requested_document_type: "OTHER",
                  })
                }
                style={{ background: "#b42318", fontSize: "13px", padding: "8px 14px", marginTop: "6px" }}
              >
                추가자료 요청 (Request Documents)
              </button>
            </div>

            {/* Finalize after additional documents */}
            <div style={{ marginTop: "12px", padding: "14px", background: "#eff6ff", borderRadius: "8px", border: "1px solid #bfdbfe" }}>
              <label style={{ fontSize: "13px", fontWeight: "bold", display: "block", marginBottom: "8px" }}>
                추가자료 반영 최종 판정 및 종결:
                <select
                  value={finalEligibility}
                  onChange={(e) => setFinalEligibility(e.target.value)}
                  style={{ marginLeft: "0.5rem" }}
                >
                  <option value="PAYABLE">지급요건 충족 (PAYABLE)</option>
                  <option value="NOT_PAYABLE">부지급 (NOT_PAYABLE)</option>
                </select>
              </label>
              <button
                onClick={() =>
                  void action("finalize", {
                    final_eligibility: finalEligibility,
                    opinion,
                  })
                }
                style={{ background: "#155eef", fontSize: "13px", padding: "8px 16px", fontWeight: "bold" }}
              >
                추가자료 반영 종결 (Finalize)
              </button>
            </div>
          </div>
        )}

        {["APPROVED", "MODIFIED", "UNDETERMINED"].includes(item.review_status) && (
          <div style={{ marginTop: "10px" }}>
            <button
              onClick={() => void action("complete")}
              style={{ background: "#027a48", padding: "10px 24px", fontWeight: "bold" }}
            >
              최종 검토 완료 (Complete)
            </button>
          </div>
        )}

        {message && (
          <p style={{ marginTop: "12px", fontWeight: "bold", color: message.includes("성공") ? "#027a48" : "#b42318" }}>
            {message}
          </p>
        )}
      </section>
    </main>
  );
}
