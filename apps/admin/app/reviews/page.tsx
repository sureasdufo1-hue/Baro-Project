"use client";
import Link from "next/link";
import {useEffect,useState} from "react";
const api=process.env.NEXT_PUBLIC_API_URL??"http://localhost:8000";
type Review={review_id:string;review_type:string;review_status:string;reason:string;requested_at:string};
export default function ReviewDashboard(){const [items,setItems]=useState<Review[]>([]),[status,setStatus]=useState("");useEffect(()=>{fetch(`${api}/api/reviews/my${status?`?status=${status}`:""}`,{credentials:"include"}).then(async r=>{if(r.ok)setItems(await r.json())})},[status]);return <main><h1>전문가 Review Dashboard</h1><p>배정된 Case만 표시됩니다.</p><label>Queue<select value={status} onChange={e=>setStatus(e.target.value)}><option value="">전체</option><option value="ASSIGNED">검토 대기</option><option value="IN_PROGRESS">검토 중</option><option value="COMPLETED">완료</option></select></label>{items.map(item=><article className="card" key={item.review_id}><span>{item.review_status}</span><h2>{item.review_type}</h2><p>{item.reason}</p><small>{new Date(item.requested_at).toLocaleString("ko-KR")}</small><p><Link href={`/reviews/${item.review_id}`}>검토 열기</Link></p></article>)}</main>}
