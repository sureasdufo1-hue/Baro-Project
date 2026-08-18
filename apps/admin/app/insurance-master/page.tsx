"use client";
import { FormEvent, useEffect, useState } from "react";

type Company={company_id:string;company_code:string;company_name:string;status:string};
const api=process.env.NEXT_PUBLIC_API_URL??"http://localhost:8000";

export default function InsuranceMasterPage(){
 const [companies,setCompanies]=useState<Company[]>([]); const [message,setMessage]=useState("");
 async function load(){const r=await fetch(`${api}/api/admin/insurance-companies`,{credentials:"include"});if(r.ok)setCompanies(await r.json());else setMessage("보험 기준정보 조회 권한이 필요합니다.");}
 useEffect(()=>{fetch(`${api}/api/admin/insurance-companies`,{credentials:"include"}).then(async r=>{if(r.ok)setCompanies(await r.json());else setMessage("보험 기준정보 조회 권한이 필요합니다.");});},[]);
 async function createCompany(e:FormEvent<HTMLFormElement>){e.preventDefault();const f=new FormData(e.currentTarget);const r=await fetch(`${api}/api/admin/insurance-companies`,{method:"POST",credentials:"include",headers:{"Content-Type":"application/json"},body:JSON.stringify({company_code:f.get("code"),company_name:f.get("name"),company_type:f.get("type")})});setMessage(r.ok?"보험회사를 등록했습니다.":"등록에 실패했습니다.");if(r.ok){e.currentTarget.reset();await load();}}
 return <main><h1>보험 기준정보</h1><p>ADM-SCR-010~050 Foundation. Rule 실행과 약관 PDF 자동분석은 제공하지 않습니다.</p>{message&&<p className="card">{message}</p>}
 <div className="grid"><section className="card"><h2>보험회사 등록</h2><form onSubmit={createCompany}><input name="code" placeholder="회사 코드" required/><input name="name" placeholder="회사명" required/><input name="type" placeholder="회사 유형" required/><button>등록</button></form></section>
 <section className="card"><h2>관리 영역</h2><ul><li>보험상품 / ProductVersion</li><li>Policy / PolicyVersion / Clause</li><li>Coverage / Alias</li><li>BenefitRule / RuleVersion</li></ul><p>각 항목은 관리자 API로 버전 단위 관리됩니다.</p></section></div>
 <section className="card"><h2>보험회사 목록</h2><table><thead><tr><th>Code</th><th>Name</th><th>Status</th></tr></thead><tbody>{companies.map(c=><tr key={c.company_id}><td>{c.company_code}</td><td>{c.company_name}</td><td>{c.status}</td></tr>)}</tbody></table></section></main>;
}
