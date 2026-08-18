import Link from "next/link";

export default function LandingPage() {
  return (
    <main>
      <section className="card">
        <p>정액형 제3보험 분석 Foundation</p>
        <h1>보험금 결과보다 먼저, 근거가 연결되는 구조를 만듭니다.</h1>
        <p>현재 단계는 회원·동의·인증 기반만 제공합니다. 보험금 계산 기능은 아직 구현되지 않았습니다.</p>
        <div className="actions">
          <Link className="button" href="/register">회원가입</Link>
          <Link className="button secondary" href="/login">로그인</Link>
        </div>
      </section>
    </main>
  );
}

