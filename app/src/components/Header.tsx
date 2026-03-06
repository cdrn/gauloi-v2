"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { ConnectButton } from "@rainbow-me/rainbowkit";

function PixelConnectButton() {
  return (
    <ConnectButton.Custom>
      {({ account, chain, openAccountModal, openChainModal, openConnectModal, mounted }) => {
        const connected = mounted && account && chain;

        return (
          <div
            {...(!mounted && {
              "aria-hidden": true,
              style: { opacity: 0, pointerEvents: "none", userSelect: "none" },
            })}
          >
            {!connected ? (
              <button onClick={openConnectModal} className="pixel-btn text-[10px] py-2 px-4 sm:py-3 sm:px-6">
                CONNECT
              </button>
            ) : chain.unsupported ? (
              <button onClick={openChainModal} className="pixel-btn-amber text-[10px] py-2 px-4 sm:py-3 sm:px-6">
                WRONG NETWORK
              </button>
            ) : (
              <div className="flex items-center gap-2">
                <button
                  onClick={openChainModal}
                  className="hidden sm:block font-pixel text-[8px] text-teal-600 hover:text-teal-400 border-2 border-navy-600 hover:border-teal-600 px-3 py-2 bg-navy-800 transition-colors"
                >
                  {chain.name?.toUpperCase() ?? "CHAIN"}
                </button>
                <button
                  onClick={openAccountModal}
                  className="font-pixel text-[10px] text-pixel-cyan border-2 border-teal-600 px-3 py-2 sm:px-4 bg-navy-800 hover:bg-navy-700 transition-colors"
                  style={{ boxShadow: "2px 2px 0px #009a7a" }}
                >
                  {account.displayName}
                </button>
              </div>
            )}
          </div>
        );
      }}
    </ConnectButton.Custom>
  );
}

export function Header() {
  const pathname = usePathname();

  const navLink = (href: string, label: string) => {
    const active = pathname === href;
    return (
      <Link
        href={href}
        className={`font-pixel text-[8px] sm:text-xs uppercase tracking-wider px-2 py-1 sm:px-4 sm:py-2 border-2 transition-colors shrink-0 ${
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
    <header className="border-b-2 border-navy-600 bg-navy-900 px-4 py-3 sm:px-6 sm:py-4">
      <div className="flex items-center justify-between gap-4">
        <div className="flex items-center gap-4 sm:gap-6 min-w-0">
          <Link href="/" className="font-pixel text-sm sm:text-lg text-pixel-cyan tracking-wider shrink-0">
            GAULOI
          </Link>
          <nav className="flex items-center gap-0 sm:gap-1 overflow-x-auto">
            {navLink("/", "Swap")}
            {navLink("/request", "Request")}
            {navLink("/activity", "Activity")}
            {navLink("/stats", "Stats")}
            {navLink("/maker", "Maker")}
          </nav>
        </div>
        <div className="shrink-0">
          <PixelConnectButton />
        </div>
      </div>
    </header>
  );
}
