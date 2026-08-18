import Link from "next/link";
import "./globals.css";

export const metadata = { title: "ClaimLens AI", description: "보험금 산정 지원 시스템" };

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="ko">
      <body>
        <header><strong>ClaimLens AI</strong><nav><Link href="/dashboard">Dashboard</Link></nav></header>
        {children}
      </body>
    </html>
  );
}

