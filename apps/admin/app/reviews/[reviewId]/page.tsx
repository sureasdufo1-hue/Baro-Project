"use client";
/* eslint-disable react-hooks/set-state-in-effect */
/* eslint-disable react-hooks/exhaustive-deps */
import {useParams} from "next/navigation";
import {useEffect,useState} from "react";
const api=process.env.NEXT_PUBLIC_API_URL??"http://localhost:8000";const web=process.env.NEXT_PUBLIC_WEB_URL??"http://localhost:3000";
type Review={claim_id:string;review_type:string;review_status:string;reason:string;previous_result:Record<string,unknown>};
export default function ReviewDetail() {
  const { reviewId } = useParams<{ reviewId: string }>();
  const [item, setItem] = useState<Review | null>(null);
  const [opinion, setOpinion] = useState("");
  const [reason, setReason] = useState("");
  const [finalEligibility, setFinalEligibility] = useState("PAYABLE");
  const [message, setMessage] = useState("");

  async function load() {
    const r = await fetch(`${api}/api/reviews/${reviewId}`, { credentials: "include" });
    if (r.ok) setItem(await r.json());
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
    setMessage(r.ok ? "처리되었습니다." : "상태와 필수 입력을 확인하세요.");
    await load();
  }

  if (!item)
    return (
      <main>
        <p>Review를 불러오는 중…</p>
      </main>
    );

  return (
    <main>
      <h1>Claim Review</h1>
      <p>
        {item.claim_id} · {item.review_type} · {item.review_status}
      </p>
      <section className="card">
        <h2>자동판단과 Evidence</h2>
        <p>{item.reason}</p>
        <pre>{JSON.stringify(item.previous_result, null, 2)}</pre>
        <a href={`${web}/claims/${item.claim_id}/result`} target="_blank" rel="noreferrer">
          결과·계산근거 열기
        </a>
      </section>
      <section className="card">
        <h2>전문가 Action</h2>
        {item.review_status === "ASSIGNED" && (
          <button onClick={() => void action("accept")}>검토 시작</button>
        )}
        <label>
          전문가 의견
          <textarea value={opinion} onChange={(e) => setOpinion(e.target.value)} />
        </label>
        <label>
          판단불가/자료요청 사유
          <textarea value={reason} onChange={(e) => setReason(e.target.value)} />
        </label>
        {item.review_status === "IN_PROGRESS" && (
          <div>
            <button onClick={() => void action("approve", { opinion })}>승인</button>
            <button
              onClick={() =>
                void action("request-documents", {
                  reason,
                  user_message: reason,
                  requested_document_type: "OTHER",
                })
              }
            >
              추가자료 요청
            </button>
            <button onClick={() => void action("undetermined", { reason, opinion })}>
              판단불가
            </button>
            <div style={{ marginTop: "1rem", paddingTop: "0.5rem", borderTop: "1px solid #ddd" }}>
              <label>
                추가자료 반영 판정:
                <select
                  value={finalEligibility}
                  onChange={(e) => setFinalEligibility(e.target.value)}
                  style={{ marginLeft: "0.5rem", marginRight: "0.5rem" }}
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
              >
                추가자료 반영 종결
              </button>
            </div>
          </div>
        )}
        {["APPROVED", "MODIFIED", "UNDETERMINED"].includes(item.review_status) && (
          <button onClick={() => void action("complete")}>검토 완료</button>
        )}
        {message && <p>{message}</p>}
      </section>
    </main>
  );
}
