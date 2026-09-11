import Link from "next/link";
import "./globals.css";
export const metadata = { title: "ClaimLens Admin" };
export default function AdminLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="ko"><body><div className="shell"><aside><strong>ClaimLens Admin</strong><nav><Link href="/">Dashboard</Link><Link href="/intake">⚡ 사건 원스톱 접수</Link><Link href="/insurance-master">보험 기준정보</Link><Link href="/policy-verification">약관 검증 Queue</Link><Link href="/reviews">Claim Review</Link><Link href="/review-admin">검토 관리</Link><Link href="/settings">⚙️ 손해사정사 설정</Link><Link href="/login">Login</Link></nav></aside>{children}</div></body></html>;
}
