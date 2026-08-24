"use client";

import Image from "next/image";
import Link from "next/link";
import { useState } from "react";

interface ProcessStep {
  id: string;
  icon: string;
  label: string;
  tagline: string;
  detail: string;
  targetHref: string;
  actionText: string;
  badge?: string;
  accent?: boolean;
  success?: boolean;
}

const processSteps: ProcessStep[] = [
  {
    id: "upload",
    icon: "upload",
    label: "문서 업로드",
    tagline: "진단서·사고자료",
    detail: "병원 진단서, 입·퇴원 확인서, 진료비 세부내역서, 영수증 등 청구에 필요한 서류를 안전하게 업로드합니다.",
    targetHref: "/claims/new",
    actionText: "문서 업로드 시작하기",
    badge: "1단계",
  },
  {
    id: "ocr",
    icon: "scan",
    label: "OCR 인식",
    tagline: "문서 내용 추출",
    detail: "광학 문자 인식(OCR) 엔진이 업로드된 의료 서류에서 텍스트와 좌표를 높은 신뢰도로 자동 판독합니다.",
    targetHref: "/claims/new",
    actionText: "OCR 인식 원리 확인",
    badge: "2단계",
  },
  {
    id: "ai",
    icon: "ai",
    label: "AI 분석",
    tagline: "의료정보 구조화",
    detail: "인공지능 모델이 진단명, 질병분류코드(KCD), 수술명, 입원일수, 급여/비급여 본인부담금을 정밀 구조화합니다.",
    targetHref: "/claims/new",
    actionText: "AI 팩트 추출 시작",
    badge: "핵심 AI",
    accent: true,
  },
  {
    id: "policy",
    icon: "policy",
    label: "보험 약관 확인",
    tagline: "적용 버전·담보",
    detail: "사고일 기준 유효한 약관 버전과 가입 담보(암, 뇌/심장, 수술, 입원, 실손, 후유장해 등)를 자동으로 매핑합니다.",
    targetHref: "/contracts",
    actionText: "보유 계약 및 담보 확인",
    badge: "4단계",
  },
  {
    id: "calc",
    icon: "won",
    label: "보험금 산정",
    tagline: "결정론적 계산",
    detail: "승인된 약관 산정 규칙과 비례지급/공제 룰을 기반으로 오차 없는 결정론적 예상 보험금을 계산합니다.",
    targetHref: "/claims/new",
    actionText: "예상 보험금 계산하기",
    badge: "5단계",
  },
  {
    id: "done",
    icon: "check",
    label: "산정 완료",
    tagline: "근거와 함께 확인",
    detail: "최종 산정 금액과 함께 적용 조항, 계산 산출식, 원본 서류 근거가 포함된 투명한 리포트를 제공합니다.",
    targetHref: "/claims",
    actionText: "청구 내역 전체 보기",
    badge: "완료",
    success: true,
  },
];

const features = [
  ["document", "진단서·사고자료 분석", "업로드한 자료에서 진단명, 코드, 날짜 등 필요한 정보를 구조화합니다."],
  ["shield", "보험약관 자동 확인", "계약일과 사고일을 기준으로 적용할 약관 버전과 가입 담보를 찾습니다."],
  ["calculator", "예상 보험금 산정", "검증된 정보와 버전이 고정된 규칙만 사용해 예상 금액을 계산합니다."],
  ["evidence", "산정 근거 확인", "계산식부터 약관 조항과 원본 문서 위치까지 한 흐름으로 확인합니다."],
] as const;

function LineIcon({ name }: { name: string }) {
  const common = {
    fill: "none",
    stroke: "currentColor",
    strokeWidth: 1.9,
    strokeLinecap: "round" as const,
    strokeLinejoin: "round" as const,
  };
  const paths: Record<string, React.ReactNode> = {
    upload: (
      <>
        <path d="M7 3.5h7l4 4V20H7z" {...common} />
        <path d="M14 3.5V8h4M12.5 17v-6m-2 2 2-2 2 2" {...common} />
      </>
    ),
    scan: (
      <>
        <path
          d="M4 8V5a1 1 0 0 1 1-1h3m8 0h3a1 1 0 0 1 1 1v3M4 16v3a1 1 0 0 0 1 1h3m8 0h3a1 1 0 0 0 1-1v-3"
          {...common}
        />
        <path d="M8 12h8" {...common} />
      </>
    ),
    ai: (
      <>
        <path
          d="M9 5.5A3 3 0 0 0 5.5 9v1A3 3 0 0 0 6 15.9V17a2 2 0 0 0 3 1.7M15 5.5A3 3 0 0 1 18.5 9v1a3 3 0 0 1-.5 5.9V17a2 2 0 0 1-3 1.7M9 5.5v13M15 5.5v13M9 9H7m8 0h2m-8 5H7m8 0h2"
          {...common}
        />
      </>
    ),
    policy: (
      <>
        <path d="M7 4h10v16H7zM9.5 8h5M9.5 12h5" {...common} />
        <path d="m10 16 1.4 1.4L15 14" {...common} />
      </>
    ),
    won: (
      <>
        <rect x="4" y="5" width="16" height="14" rx="2" {...common} />
        <path d="m8 9 2 6 2-6 2 6 2-6M7 12h10" {...common} />
      </>
    ),
    check: (
      <>
        <circle cx="12" cy="12" r="8.5" {...common} />
        <path d="m8.5 12 2.2 2.2 4.8-5" {...common} />
      </>
    ),
    document: (
      <>
        <path d="M7 3.5h7l4 4V20H7zM14 3.5V8h4M9.5 12h5M9.5 16h4" {...common} />
      </>
    ),
    shield: (
      <>
        <path d="M12 3 19 6v5c0 4.4-2.8 7.8-7 10-4.2-2.2-7-5.6-7-10V6z" {...common} />
        <path d="m8.7 11.5 2.1 2.1 4.4-4.5" {...common} />
      </>
    ),
    calculator: (
      <>
        <rect x="5" y="3.5" width="14" height="17" rx="2" {...common} />
        <path d="M8 7h8M8 11h1m3 0h1m3 0h.1M8 15h1m3 0h1m3 0h.1" {...common} />
      </>
    ),
    evidence: (
      <>
        <path d="M7 4h10v16H7zM9.5 8h5M9.5 12h3" {...common} />
        <circle cx="15.5" cy="15.5" r="3" {...common} />
        <path d="m17.8 17.8 2 2" {...common} />
      </>
    ),
    lock: (
      <>
        <rect x="5" y="10" width="14" height="10" rx="2" {...common} />
        <path d="M8.5 10V7.5a3.5 3.5 0 0 1 7 0V10M12 14v2" {...common} />
      </>
    ),
    arrow: (
      <path d="M5 12h14m-6-6 6 6-6 6" {...common} />
    ),
  };
  return <svg viewBox="0 0 24 24" aria-hidden="true">{paths[name] ?? paths.check}</svg>;
}

export default function LandingPage() {
  const [activeStepIndex, setActiveStepIndex] = useState<number>(0);
  const activeStep = processSteps[activeStepIndex];

  return (
    <main className="landing-main">
      <section className="landing-hero" aria-labelledby="hero-title">
        <div className="hero-copy">
          <p className="hero-badge">
            <span aria-hidden="true">✦</span> AI 기반 보험금 산정 지원
          </p>
          <h1 id="hero-title">
            복잡한 보험금 분석,<br />
            <span>AI가 쉽게</span> 도와드려요
          </h1>
          <p className="hero-description">
            진단서와 사고자료를 올리면 적용 약관과 가입 담보를 확인하고,
            예상 보험금과 계산 근거를 알기 쉽게 보여드립니다.
          </p>
          <div className="hero-actions">
            <Link className="button hero-primary" href="/claims/new">
              보험금 분석 시작 <span aria-hidden="true">→</span>
            </Link>
            <a className="button hero-secondary" href="#pipeline-interactive">
              프로세스 단계 알아보기
            </a>
          </div>
          <ul className="hero-trust" aria-label="서비스 보호 원칙">
            <li>
              <LineIcon name="lock" /> 안전한 문서 처리
            </li>
            <li>
              <LineIcon name="shield" /> 검증된 정보로 산정
            </li>
          </ul>
        </div>
        <div className="mascot-visual">
          <div className="mascot-glow" aria-hidden="true" />
          <Image
            className="mascot-image"
            src="/brand/insurance-ai-mascot.png"
            alt="보험금 분석을 도와주는 친근한 AI 보험 도우미"
            width={1672}
            height={941}
            priority
            unoptimized
            sizes="(max-width: 767px) 94vw, (max-width: 1199px) 54vw, 720px"
          />
          <div className="floating-card floating-ai">
            <span>AI</span>
            <strong>진단서 분석</strong>
            <small>의료정보를 구조화해요</small>
          </div>
          <div className="floating-card floating-safe">
            <span aria-hidden="true">✓</span>
            <strong>분석 준비 완료</strong>
            <small>검증 후 산정을 시작해요</small>
          </div>
        </div>
      </section>

      {/* 반응형 인터랙티브 프로세스 메뉴 (Hero 하단 연동) */}
      <section
        className="pipeline-menu-section"
        id="pipeline-interactive"
        aria-labelledby="pipeline-menu-title"
      >
        <div className="pipeline-header">
          <div className="pipeline-title-group">
            <span className="pipeline-kicker">INTERACTIVE PIPELINE MENU</span>
            <h2 id="pipeline-menu-title">6단계 스마트 보험금 분석 여정</h2>
          </div>
          <p className="pipeline-subtitle">
            원하는 단계를 클릭하면 AI 분석 과정과 상세 내용을 바로 확인하실 수 있습니다.
          </p>
        </div>

        {/* 반응형 단계 메뉴 바 (Responsive Process Navigation) */}
        <nav
          className="responsive-process-bar"
          aria-label="보험금 분석 6단계 진행 메뉴"
        >
          {processSteps.map((step, index) => {
            const isActive = index === activeStepIndex;
            return (
              <button
                key={step.id}
                type="button"
                className={`process-nav-item ${isActive ? "is-active" : ""} ${
                  step.accent ? "is-accent" : ""
                } ${step.success ? "is-success" : ""}`}
                onClick={() => setActiveStepIndex(index)}
                aria-pressed={isActive}
                aria-label={`${index + 1}단계: ${step.label} (${step.tagline})`}
              >
                <div className="nav-item-top">
                  <span className="nav-step-number">
                    {String(index + 1).padStart(2, "0")}
                  </span>
                  {step.badge && (
                    <span className="nav-badge">{step.badge}</span>
                  )}
                </div>
                <div className="nav-icon-wrap">
                  <LineIcon name={step.icon} />
                </div>
                <strong className="nav-label">{step.label}</strong>
                <span className="nav-tagline">{step.tagline}</span>
                {isActive && <div className="active-glow-indicator" />}
              </button>
            );
          })}
        </nav>

        {/* 선택된 단계 인터랙티브 상세 카드 (Detail Banner) */}
        <div className="pipeline-detail-card">
          <div className="detail-left">
            <div className="detail-badge-row">
              <span className="detail-step-badge">
                STEP {String(activeStepIndex + 1).padStart(2, "0")} / 06
              </span>
              <span className="detail-status-pill">
                {activeStep.label}
              </span>
            </div>
            <h3 className="detail-title">{activeStep.tagline}</h3>
            <p className="detail-desc">{activeStep.detail}</p>
          </div>
          <div className="detail-actions">
            <Link className="button detail-action-btn" href={activeStep.targetHref}>
              {activeStep.actionText} <LineIcon name="arrow" />
            </Link>
            <div className="detail-stepper-controls">
              <button
                type="button"
                className="step-ctrl-btn"
                disabled={activeStepIndex === 0}
                onClick={() => setActiveStepIndex((prev) => Math.max(0, prev - 1))}
                aria-label="이전 단계 보기"
              >
                ← 이전
              </button>
              <button
                type="button"
                className="step-ctrl-btn"
                disabled={activeStepIndex === processSteps.length - 1}
                onClick={() =>
                  setActiveStepIndex((prev) =>
                    Math.min(processSteps.length - 1, prev + 1)
                  )
                }
                aria-label="다음 단계 보기"
              >
                다음 →
              </button>
            </div>
          </div>
        </div>
      </section>

      <section className="feature-section" aria-labelledby="feature-title">
        <div className="section-heading">
          <p>SMART &amp; TRACEABLE</p>
          <h2 id="feature-title">쉽게 확인하고, 근거까지 투명하게</h2>
        </div>
        <div className="feature-grid">
          {features.map(([icon, title, description]) => (
            <article className="feature-card" key={title}>
              <span className="feature-icon">
                <LineIcon name={icon} />
              </span>
              <h3>{title}</h3>
              <p>{description}</p>
            </article>
          ))}
        </div>
      </section>

      <section className="trust-section" aria-labelledby="trust-title">
        <div className="trust-symbol">
          <LineIcon name="shield" />
        </div>
        <div>
          <p>PRIVACY BY DESIGN</p>
          <h2 id="trust-title">중요한 보험·의료정보를 안전하게 다룹니다</h2>
          <span>
            문서는 공개 주소로 노출하지 않고, 권한이 확인된 사용자만 접근할 수
            있습니다.
          </span>
        </div>
        <Link className="text-link" href="/register">
          안전하게 시작하기 <span aria-hidden="true">→</span>
        </Link>
      </section>

      <footer className="landing-footer">
        <strong>ClaimLens AI</strong>
        <p>
          예상 산정 결과는 실제 보험회사의 심사·지급 결과와 다를 수 있습니다.
        </p>
      </footer>
    </main>
  );
}

