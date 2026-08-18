import Link from "next/link";
import "./globals.css";

export const metadata = { title: "ClaimLens AI", description: "보험금 산정 지원 시스템" };

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="ko">
      <body>
        <header className="site-header">
          <Link className="brand" href="/" aria-label="ClaimLens AI 홈">
            <span className="brand-mark" aria-hidden="true">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2"><path d="m7 12 3 3 7-7"/></svg>
            </span>
            <strong>ClaimLens AI</strong>
          </Link>
          <nav className="site-nav" aria-label="주요 메뉴">
            <Link href="/claims/new">보험금 분석</Link>
            <Link href="/claims">분석 내역</Link>
            <Link href="/contracts">보장 내역</Link>
            <Link href="/#how-it-works">이용 안내</Link>
          </nav>
          <div className="header-actions">
            <Link className="header-link" href="/login">로그인</Link>
            <Link className="header-cta" href="/register">무료로 시작하기</Link>
          </div>
        </header>
        {children}
      </body>
    </html>
  );
}
