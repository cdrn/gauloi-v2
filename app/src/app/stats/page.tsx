"use client";

import { useNetworkStats } from "@/hooks/useNetworkStats";
import { UI_CHAINS } from "@/config/chains";
import { formatUnits } from "viem";

function truncateAddress(addr: string): string {
  return `${addr.slice(0, 6)}...${addr.slice(-4)}`;
}

function getChainName(chainId: string): string {
  const id = Number(chainId);
  const chain = UI_CHAINS.find((c) => c.chainId === id);
  return chain?.name ?? `Chain ${chainId}`;
}

export default function StatsPage() {
  const stats = useNetworkStats(10_000);

  if (!stats) {
    return (
      <div className="pixel-border bg-navy-900 p-6 text-center font-pixel text-[10px] text-teal-600 py-12 animate-pulse">
        LOADING STATS...
      </div>
    );
  }

  const volume = stats.intents.volume !== "0"
    ? formatUnits(BigInt(stats.intents.volume), 6)
    : "0";

  return (
    <div className="space-y-4">
      <h2 className="font-pixel text-sm text-pixel-cyan">NETWORK STATS</h2>

      {/* Intent stats grid */}
      <div className="grid grid-cols-2 gap-3">
        <div className="pixel-border bg-navy-900 p-4">
          <p className="font-pixel text-[8px] text-teal-600 uppercase mb-1">Total Intents</p>
          <p className="font-pixel text-lg text-pixel-cyan">{stats.intents.total}</p>
        </div>
        <div className="pixel-border bg-navy-900 p-4">
          <p className="font-pixel text-[8px] text-teal-600 uppercase mb-1">Open</p>
          <p className="font-pixel text-lg text-pixel-green">{stats.intents.open}</p>
        </div>
        <div className="pixel-border bg-navy-900 p-4">
          <p className="font-pixel text-[8px] text-teal-600 uppercase mb-1">Filled</p>
          <p className="font-pixel text-lg text-pixel-cyan">{stats.intents.filled}</p>
        </div>
        <div className="pixel-border bg-navy-900 p-4">
          <p className="font-pixel text-[8px] text-teal-600 uppercase mb-1">Volume (USDC)</p>
          <p className="font-pixel text-lg text-pixel-cyan">{Number(volume).toLocaleString()}</p>
        </div>
      </div>

      {/* Per-chain maker list */}
      <div className="pixel-border bg-navy-900 p-4 space-y-4">
        <p className="font-pixel text-[10px] text-pixel-cyan uppercase">Active Makers</p>

        {Object.keys(stats.makers).length === 0 ? (
          <p className="font-pixel text-[8px] text-teal-600">NO MAKERS ONLINE</p>
        ) : (
          Object.entries(stats.makers)
            .filter(([chainId]) => chainId !== "0")
            .map(([chainId, data]) => (
              <div key={chainId} className="space-y-2">
                <div className="flex items-center justify-between">
                  <span className="font-pixel text-[8px] text-teal-600 uppercase">
                    {getChainName(chainId)}
                  </span>
                  <span className="font-pixel text-[8px] text-pixel-green flex items-center gap-1">
                    <span className="w-1.5 h-1.5 bg-pixel-green inline-block" />
                    {data.count} ONLINE
                  </span>
                </div>
                <div className="space-y-1">
                  {data.addresses.map((addr) => (
                    <div
                      key={addr}
                      className="bg-navy-800 border-2 border-navy-600 px-3 py-2 font-mono text-[10px] text-teal-400"
                    >
                      {truncateAddress(addr)}
                    </div>
                  ))}
                </div>
              </div>
            ))
        )}
      </div>
    </div>
  );
}
