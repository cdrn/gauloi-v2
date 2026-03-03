"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { ConnectButton } from "@rainbow-me/rainbowkit";

export function Header() {
  const pathname = usePathname();

  return (
    <header className="border-b border-gray-800 px-6 py-4 flex items-center justify-between">
      <div className="flex items-center gap-8">
        <Link href="/" className="text-xl font-bold tracking-tight">
          gauloi
        </Link>
        <nav className="flex gap-4 text-sm">
          <Link
            href="/"
            className={`transition-colors ${
              pathname === "/" ? "text-white" : "text-gray-400 hover:text-white"
            }`}
          >
            Swap
          </Link>
          <Link
            href="/request"
            className={`transition-colors ${
              pathname === "/request" ? "text-white" : "text-gray-400 hover:text-white"
            }`}
          >
            Request
          </Link>
          <Link
            href="/activity"
            className={`transition-colors ${
              pathname === "/activity" ? "text-white" : "text-gray-400 hover:text-white"
            }`}
          >
            Activity
          </Link>
        </nav>
      </div>
      <ConnectButton showBalance={false} />
    </header>
  );
}
