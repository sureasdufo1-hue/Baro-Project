"use client";

import { FormEvent, useCallback, useEffect, useState } from "react";
import { useRouter } from "next/navigation";

const api = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000";
type Contract = { contract_id: string; insured_id: string; policy_number: string | null; contract_status: string; coverage_start_date: string | null; coverage_end_date: string | null };
const nullableString = (value: unknown): value is string | null => value === null || typeof value === "string";

export function parseContracts(data: unknown): Contract[] {
  if (!Array.isArray(data)) throw new Error("Invalid contracts API response");
  if (!data.every((item): item is Contract => {
    if (typeof item !== "object" || item === null) return false;
    const value = item as Record<string, unknown>;
    return typeof value.contract_id === "string" && typeof value.insured_id === "string"
      && nullableString(value.policy_number) && typeof value.contract_status === "string"
      && nullableString(value.coverage_start_date) && nullableString(value.coverage_end_date);
  })) throw new Error("Invalid contract in API response");
  return data;
}

async function fetchContracts(signal?: AbortSignal): Promise<Contract[]> {
  const response = await fetch(`${api}/api/contracts`, { credentials: "include", signal });
  if (!response.ok) throw new Error(`Failed to load contracts: ${response.status}`);
  return parseContracts(await response.json() as unknown);
}

export default function NewClaimPage() {
  const router = useRouter();
  const [contracts, setContracts] = useState<Contract[]>([]);
  const [contractsStatus, setContractsStatus] = useState<"loading" | "success" | "error">("loading");
  const [type, setType] = useState("DISEASE");
  const [message, setMessage] = useState("");

  const loadContracts = useCallback(async (signal?: AbortSignal) => {
    try {
      const parsed = await fetchContracts(signal);
      if (!signal?.aborted) { setContracts(parsed); setContractsStatus("success"); }
    } catch (error) {
      if (error instanceof DOMException && error.name === "AbortError") return;
      if (!signal?.aborted) { setContracts([]); setContractsStatus("error"); }
    }
  }, []);

  useEffect(() => {
    const controller = new AbortController();
    void fetchContracts(controller.signal).then((parsed) => {
      setContracts(parsed);
      setContractsStatus("success");
    }).catch((error: unknown) => {
      if (error instanceof DOMException && error.name === "AbortError") return;
      setContracts([]);
      setContractsStatus("error");
    });
    return () => controller.abort();
  }, []);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); setMessage("");
    if (contractsStatus !== "success" || contracts.length === 0) { setMessage("보험계약을 불러온 후 다시 시도해주세요."); return; }
    const form = new FormData(event.currentTarget);
    const accident = {
      accident_date: type === "INJURY" ? form.get("accidentDate") || null : null,
      diagnosis_date: type === "DISEASE" ? form.get("diagnosisDate") || null : null,
      onset_date: type === "DISEASE" ? form.get("onsetDate") || null : null,
      location: type === "INJURY" ? form.get("location") || null : null,
      description: form.get("description") || null,
    };
    try {
      const created = await fetch(`${api}/api/claims`, { method: "POST", credentials: "include", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ contract_id: form.get("contract"), claim_type: type, title: form.get("title") || null, accident }) });
      if (!created.ok) {
        setMessage(created.status === 401 || created.status === 403 ? "로그인 정보가 만료되었습니다. 다시 로그인해주세요." : `계약과 사고·질병 정보를 확인하세요. (오류 ${created.status})`);
        return;
      }
      const claim = await created.json() as { claim_id: string };
      const moved = await fetch(`${api}/api/claims/${claim.claim_id}/transitions`, { method: "POST", credentials: "include", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ action: "SUBMIT_ACCIDENT_INFORMATION" }) });
      if (moved.ok) router.push(`/claims/${claim.claim_id}?created=1`);
      else setMessage("Case는 저장되었지만 사고정보 완료 처리에 실패했습니다.");
    } catch { setMessage("서버에 연결할 수 없습니다. 잠시 후 다시 시도해주세요."); }
  }

  const empty = contractsStatus === "success" && contracts.length === 0;
  return <main><section className="card">
    <div className="stepper"><strong>① 사고정보</strong><span>② 문서등록</span><span>③ 정보확인</span><span>④ 분석</span><span>⑤ 결과</span></div>
    <h1>새로운 보험금 분석</h1>
    <form onSubmit={submit}>
      <fieldset><legend>발생유형</legend><div className="choice-row">{[["DISEASE", "질병"], ["INJURY", "상해"], ["OTHER", "기타"]].map(([value, label]) => <label className="choice" key={value}><input type="radio" name="type" value={value} checked={type === value} onChange={() => setType(value)} />{label}</label>)}</div></fieldset>
      <label>분석할 보험계약<select name="contract" required disabled={contractsStatus !== "success" || empty}>
        <option value="">{contractsStatus === "loading" ? "보험계약 불러오는 중..." : contractsStatus === "error" ? "계약 정보를 불러올 수 없음" : empty ? "등록된 보험계약 없음" : "선택"}</option>
        {contracts.map((contract) => <option key={contract.contract_id} value={contract.contract_id}>{contract.policy_number ?? "증권번호 미입력"} · {contract.coverage_start_date ?? "기간 미입력"} · {contract.contract_status}</option>)}
      </select></label>
      {contractsStatus === "error" && <p role="alert">보험계약 정보를 불러오지 못했습니다. <button type="button" onClick={() => { setContractsStatus("loading"); void loadContracts(); }}>다시 시도</button></p>}
      {empty && <p role="status">등록된 보험계약이 없습니다. 먼저 보험계약을 등록해주세요.</p>}
      <label>Case 제목<input name="title" placeholder="예: 7월 교통사고 골절" /></label>
      {type === "DISEASE" && <><label>진단일<input name="diagnosisDate" type="date" /></label><label>증상/발병일<input name="onsetDate" type="date" /></label></>}
      {type === "INJURY" && <><label>사고일<input name="accidentDate" type="date" required /></label><label>사고장소<input name="location" /></label></>}
      <label>{type === "INJURY" ? "사고내용" : "내용"}<textarea name="description" required={type === "OTHER"} /></label>
      <p className="notice">입력 정보는 사용자 진술이며 문서로 확인된 사실이 아닙니다.</p>
      {message && <p role="alert">{message}</p>}
      <button className="button" disabled={contractsStatus !== "success" || empty}>Case 생성하고 다음 단계로</button>
    </form>
  </section></main>;
}
