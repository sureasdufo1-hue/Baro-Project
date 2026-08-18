"use client";

import { FormEvent, useState } from "react";
import { useRouter } from "next/navigation";

export default function RegisterPage() {
  const router = useRouter();
  const [message, setMessage] = useState("");
  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const data = new FormData(event.currentTarget);
    const response = await fetch(`${process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000"}/api/auth/register`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email: data.get("email"), password: data.get("password"), display_name: data.get("displayName"), consents: [
        { consent_type: "SERVICE_TERMS", consent_version: "1.0", agreed: true },
        { consent_type: "PRIVACY", consent_version: "1.0", agreed: true },
      ] }),
    });
    if (!response.ok) { setMessage("가입 정보를 확인하세요."); return; }
    router.push("/login");
  }
  return <main><section className="card"><h1>회원가입</h1><form onSubmit={submit}>
    <label>이름<input name="displayName" required /></label>
    <label>이메일<input name="email" type="email" required /></label>
    <label>비밀번호 (12자 이상)<input name="password" type="password" minLength={12} required /></label>
    <p>가입하면 서비스 이용약관과 개인정보 처리에 동의합니다.</p>
    {message && <p className="notice" role="alert">{message}</p>}
    <button className="button" type="submit">가입하기</button>
  </form></section></main>;
}

