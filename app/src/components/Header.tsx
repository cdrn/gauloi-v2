"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { ConnectButton } from "@rainbow-me/rainbowkit";

export function Header() {
  const pathname = usePathname();

  const navLink = (href: string, label: string) => {
    const active = pathname === href;
    return (
      <Link
        href={href}
        className={`font-pixel text-[10px] uppercase tracking-wider px-3 py-1 border-2 transition-colors ${
          active
            ? "border-teal-400 text-teal-400 bg-navy-700"
            : "border-transparent text-teal-600 hover:text-teal-400 hover:border-navy-600"
        }`}
      >
        {label}
      </Link>
    );
  };

  return (
    <header className="border-b-2 border-navy-600 px-6 py-4 flex items-center justify-between bg-navy-900">
      <div className="flex items-center gap-6">
        <Link href="/" className="font-pixel text-sm text-pixel-cyan tracking-wider">
          GAULOI
        </Link>
        <nav className="flex gap-1">
          {navLink("/", "Swap")}
          {navLink("/request", "Request")}
          {navLink("/activity", "Activity")}
        </nav>
      </div>
      <ConnectButton showBalance={false} />
    </header>
  );
}
