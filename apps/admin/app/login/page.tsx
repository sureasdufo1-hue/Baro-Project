export default function AdminLogin() {
  const web = process.env.NEXT_PUBLIC_WEB_URL ?? "http://localhost:3000";
  return <main><section className="card"><h1>관리자 로그인</h1><p>공통 인증 API를 사용합니다. 관리자 화면 접근은 서버의 RBAC 검증을 통과해야 합니다.</p><a href={`${web}/login`}>로그인 화면 열기</a></section></main>;
}
