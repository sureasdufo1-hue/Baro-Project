"use client";

import { FormEvent, useState } from "react";
import { useRouter } from "next/navigation";

export default function LoginPage() {
  const router = useRouter();
  const [message, setMessage] = useState("");
  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const data = new FormData(event.currentTarget);
    const response = await fetch(`${process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000"}/api/auth/login`, {
      method: "POST", credentials: "include", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email: data.get("email"), password: data.get("password") }),
    });
    if (!response.ok) { setMessage("이메일 또는 비밀번호를 확인하세요."); return; }
    router.push("/dashboard");
  }
  return <main><section className="card"><h1>로그인</h1><form onSubmit={submit}>
    <label>이메일<input name="email" type="email" required /></label>
    <label>비밀번호<input name="password" type="password" required /></label>
    {message && <p className="notice" role="alert">{message}</p>}
    <button className="button" type="submit">로그인</button>
  </form></section></main>;
}

