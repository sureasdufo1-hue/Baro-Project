"use client";

import Link from "next/link";
import { useEffect, useState } from "react";

const api = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000";
type QueueItem = { coverage_id:number; coverage_name:string; coverage_type:string; product_code:string; product_name:string; version_name:string; rule_status:string; approved:number; rejected:number; pending:number; eligible_for_promotion:boolean };

export default function PolicyVerificationQueue() {
  const [items,setItems] = useState<QueueItem[]>([]);
  const [message,setMessage] = useState("불러오는 중…");
  useEffect(() => { fetch(`${api}/api/admin/policy-db/verification-queue`,{credentials:"include"}).then(async response => {
    if (!response.ok) { setMessage("약관 검증 Queue 조회 권한이 필요합니다."); return; }
    const data:QueueItem[] = await response.json(); setItems(data); setMessage(data.length ? "" : "검토 대기 담보가 없습니다.");
  }).catch(() => setMessage("API 서버에 연결할 수 없습니다.")); },[]);
  return <main><h1>약관 검증 Queue</h1><p className="muted">공식 약관 근거와 추출 Rule을 사람이 대조합니다. 검토 전에는 보험금 계산에 사용되지 않습니다.</p>{message&&<p className="card">{message}</p>}{items.map(item=><article className="card" key={item.coverage_id}><span className={`badge ${item.rejected ? "rejected" : ""}`}>{item.rule_status}</span><h2>{item.coverage_name}</h2><p>{item.product_code} · {item.product_name} · {item.version_name}</p><p>승인 {item.approved} / 대기 {item.pending} / 거절 {item.rejected}</p><Link href={`/policy-verification/${item.coverage_id}`}>검토 열기</Link></article>)}</main>;
}
