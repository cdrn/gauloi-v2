"use client";

import { useAccount } from "wagmi";
import { UI_CHAINS } from "@/config/chains";
import { ChainStakeCard } from "./ChainStakeCard";

export function MakerDashboard() {
  const { address, isConnected } = useAccount();

  if (!isConnected || !address) {
    return (
      <div className="pixel-border bg-navy-900 p-6 text-center py-12">
        <p className="font-pixel text-sm text-teal-600">CONNECT WALLET</p>
        <p className="text-sm text-navy-600 mt-4">
          Connect your wallet to manage maker stakes.
        </p>
      </div>
    );
  }

  return (
    <div className="space-y-4">
      <h2 className="font-pixel text-sm text-pixel-cyan">MAKER DASHBOARD</h2>
      {UI_CHAINS.map((chain) => (
        <ChainStakeCard key={chain.chainId} chain={chain} maker={address} />
      ))}
    </div>
  );
}
