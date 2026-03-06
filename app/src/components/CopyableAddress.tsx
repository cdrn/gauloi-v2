"use client";

import { useState, useCallback } from "react";

interface CopyableAddressProps {
  address: string;
  truncate?: boolean;
  className?: string;
}

function truncateAddr(addr: string): string {
  return `${addr.slice(0, 6)}...${addr.slice(-4)}`;
}

export function CopyableAddress({ address, truncate = true, className = "" }: CopyableAddressProps) {
  const [copied, setCopied] = useState(false);

  const handleCopy = useCallback(() => {
    navigator.clipboard.writeText(address).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    });
  }, [address]);

  return (
    <button
      type="button"
      onClick={handleCopy}
      title={address}
      className={`inline-flex items-center gap-1 hover:text-pixel-cyan transition-colors cursor-pointer ${className}`}
    >
      <span>{truncate ? truncateAddr(address) : address}</span>
      <svg
        viewBox="0 0 16 16"
        fill="none"
        className="w-3 h-3 shrink-0 opacity-40 hover:opacity-100"
      >
        {copied ? (
          <path d="M3 8.5L6 11.5L13 4.5" stroke="currentColor" strokeWidth="2" />
        ) : (
          <>
            <rect x="5" y="5" width="9" height="9" rx="1" stroke="currentColor" strokeWidth="1.5" />
            <path d="M3 11V3a1 1 0 011-1h8" stroke="currentColor" strokeWidth="1.5" />
          </>
        )}
      </svg>
    </button>
  );
}
