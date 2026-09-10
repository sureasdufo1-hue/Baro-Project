import Link from "next/link";

export default function AdminDashboard() {
  return (
    <main>
      <div style={{ marginBottom: "24px" }}>
        <h1 style={{ margin: "0 0 8px 0" }}>손해사정사 통합 관리 대시보드</h1>
        <p className="notice" style={{ marginTop: 0 }}>
          인공지능 기반 손해사정 심사 및 보고서 자동화 파일럿 시스템입니다.
        </p>
      </div>

      {/* Main Action Banner */}
      <section
        className="card"
        style={{
          border: "2px solid #155eef",
          background: "linear-gradient(135deg, #eff8ff 0%, #ffffff 100%)",
          marginBottom: "20px",
          display: "flex",
          justifyContent: "space-between",
          alignItems: "center",
          flexWrap: "wrap",
          gap: "16px",
        }}
      >
        <div>
          <span className="badge" style={{ background: "#d1e9ff", color: "#0040c1", fontWeight: "bold" }}>
            FAST INTAKE & AUTO ASSESSMENT
          </span>
          <h2 style={{ margin: "8px 0", color: "#175cd3" }}>⚡ 신규 사건 원스톱 접수 및 사정 착수</h2>
          <p style={{ margin: 0, color: "#475467", maxWidth: "600px" }}>
            피보험자 등록부터 보험계약, 사고정보, 의료서류 첨부까지 단일 화면에서 일괄 처리하고,
            인공지능 팩트 추출과 결정 규칙 엔진을 통해 즉시 손해사정서 작성을 시작합니다.
          </p>
        </div>
        <Link
          href="/intake"
          style={{
            background: "#155eef",
            color: "white",
            padding: "14px 24px",
            borderRadius: "8px",
            textDecoration: "none",
            fontWeight: "bold",
            fontSize: "16px",
            boxShadow: "0 4px 10px rgba(21, 94, 239, 0.25)",
            display: "inline-block",
          }}
        >
          🚀 사건 원스톱 접수 시작
        </Link>
      </section>

      {/* Quick Nav Grid */}
      <div className="grid">
        <article className="card">
          <span className="badge approved">ADJUSTER REVIEW</span>
          <h3 style={{ margin: "10px 0 6px 0" }}>📋 내 배정 검토 목록</h3>
          <p className="muted" style={{ fontSize: "14px", margin: "0 0 14px 0" }}>
            담당 손해사정사로 배정된 사건의 3단계 소견(고지의무, 담보해당성, 종합결론)을 작성하고 확정합니다.
          </p>
          <Link href="/reviews" style={{ color: "#155eef", fontWeight: "bold", textDecoration: "none" }}>
            내 검토 Queue 열기 →
          </Link>
        </article>

        <article className="card">
          <span className="badge">SUPERVISION</span>
          <h3 style={{ margin: "10px 0 6px 0" }}>🏛️ 검토 총괄 관리</h3>
          <p className="muted" style={{ fontSize: "14px", margin: "0 0 14px 0" }}>
            전체 사건의 심사 상태를 모니터링하고, 담당 전문가를 재배정하거나 상태를 관리합니다.
          </p>
          <Link href="/review-admin" style={{ color: "#155eef", fontWeight: "bold", textDecoration: "none" }}>
            검토 관리 열기 →
          </Link>
        </article>

        <article className="card">
          <span className="badge">INSURANCE MASTER</span>
          <h3 style={{ margin: "10px 0 6px 0" }}>📚 보험 기준정보 관리</h3>
          <p className="muted" style={{ fontSize: "14px", margin: "0 0 14px 0" }}>
            보험회사, 상품 버전, 약관 조항 및 담보별 결정 규칙(Rule)을 등록하고 관리합니다.
          </p>
          <Link href="/insurance-master" style={{ color: "#155eef", fontWeight: "bold", textDecoration: "none" }}>
            기준정보 열기 →
          </Link>
        </article>

        <article className="card">
          <span className="badge">POLICY VERIFICATION</span>
          <h3 style={{ margin: "10px 0 6px 0" }}>⚖️ 약관 검증 Queue</h3>
          <p className="muted" style={{ fontSize: "14px", margin: "0 0 14px 0" }}>
            AI가 약관에서 추출한 보장 규칙의 조건 및 파라미터를 검증하고 승인합니다.
          </p>
          <Link href="/policy-verification" style={{ color: "#155eef", fontWeight: "bold", textDecoration: "none" }}>
            약관 검증 Queue 열기 →
          </Link>
        </article>
      </div>

      {/* Pilot Workflow Guide */}
      <section className="card" style={{ marginTop: "24px" }}>
        <h2>손해사정 1인 시범운영 표준 프로세스</h2>
        <div
          style={{
            display: "grid",
            gridTemplateColumns: "repeat(auto-fit, minmax(200px, 1fr))",
            gap: "16px",
            marginTop: "12px",
          }}
        >
          <div style={{ padding: "12px", background: "#f8fafc", borderRadius: "8px" }}>
            <strong style={{ color: "#155eef" }}>Step 1. 원스톱 접수</strong>
            <p style={{ margin: "6px 0 0 0", fontSize: "13px", color: "#475467" }}>
              고객 및 계약, 진단서 업로드 후 1클릭으로 사건 등록 및 OCR 파이프라인 가동.
            </p>
          </div>
          <div style={{ padding: "12px", background: "#f8fafc", borderRadius: "8px" }}>
            <strong style={{ color: "#155eef" }}>Step 2. 팩트 & 약관 판정</strong>
            <p style={{ margin: "6px 0 0 0", fontSize: "13px", color: "#475467" }}>
              KCD 질병분류코드 및 수술명 매칭, 담보 조항과 결정 규칙에 따른 결정론적 계산.
            </p>
          </div>
          <div style={{ padding: "12px", background: "#f8fafc", borderRadius: "8px" }}>
            <strong style={{ color: "#155eef" }}>Step 3. 사정의견 종합</strong>
            <p style={{ margin: "6px 0 0 0", fontSize: "13px", color: "#475467" }}>
              고지의무 검토, 의학적 소견, 결론 작성 (조문 및 금액 1클릭 자동 인용).
            </p>
          </div>
          <div style={{ padding: "12px", background: "#f8fafc", borderRadius: "8px" }}>
            <strong style={{ color: "#155eef" }}>Step 4. 보고서 발행 & 직인</strong>
            <p style={{ margin: "6px 0 0 0", fontSize: "13px", color: "#475467" }}>
              공식 한국형 6단 손해사정보고서 A4 인쇄, PDF 저장 및 직인 날인 완료.
            </p>
          </div>
        </div>
      </section>
    </main>
  );
}
