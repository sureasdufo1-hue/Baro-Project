import Link from "next/link";
import "./globals.css";
export const metadata = { title: "ClaimLens Admin" };
export default function AdminLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="ko"><body><div className="shell"><aside><strong>ClaimLens Admin</strong><nav><Link href="/">Dashboard</Link><Link href="/login">Login</Link></nav></aside>{children}</div></body></html>;
}

