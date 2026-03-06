"use client";

import { useNetworkStats } from "@/hooks/useNetworkStats";
import { useOnChainStats } from "@/hooks/useOnChainStats";
import { UI_CHAINS } from "@/config/chains";
import { formatUnits } from "viem";
import { CopyableAddress } from "@/components/CopyableAddress";

function getChainName(chainId: number): string {
  const chain = UI_CHAINS.find((c) => c.chainId === chainId);
  return chain?.name ?? `Chain ${chainId}`;
}

function formatUsdc(raw: string): string {
  if (raw === "0") return "0";
  return Number(formatUnits(BigInt(raw), 6)).toLocaleString(undefined, {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });
}

function StatCard({ label, value, color = "text-pixel-cyan" }: { label: string; value: string | number; color?: string }) {
  return (
    <div className="pixel-border bg-navy-900 p-4">
      <p className="font-pixel text-[8px] text-teal-600 uppercase mb-1">{label}</p>
      <p className={`font-pixel text-lg ${color}`}>{value}</p>
    </div>
  );
}

export default function StatsPage() {
  const relay = useNetworkStats(10_000);
  const onChain = useOnChainStats(60_000);

  if (onChain.loading) {
    return (
      <div className="pixel-border bg-navy-900 p-6 text-center font-pixel text-[10px] text-teal-600 py-12 animate-pulse">
        LOADING STATS...
      </div>
    );
  }

  // Aggregate on-chain totals across chains
  let totalOrders = 0;
  let totalSettled = 0;
  let totalVolume = 0n;
  let totalStaked = 0n;

  for (const chainStats of Object.values(onChain.chains)) {
    totalOrders += chainStats.orderCount;
    totalSettled += chainStats.settledCount;
    if (chainStats.volume !== "0") totalVolume += BigInt(chainStats.volume);
    if (chainStats.totalStaked !== "0") totalStaked += BigInt(chainStats.totalStaked);
  }

  return (
    <div className="space-y-4">
      <h2 className="font-pixel text-sm text-pixel-cyan">NETWORK STATS</h2>

      {/* On-chain aggregate stats */}
      <div className="grid grid-cols-2 gap-3">
        <StatCard label="Orders" value={totalOrders} />
        <StatCard label="Settled" value={totalSettled} color="text-pixel-green" />
        <StatCard label="Volume (USDC)" value={formatUsdc(totalVolume.toString())} />
        <StatCard label="Total Staked" value={formatUsdc(totalStaked.toString())} />
      </div>

      {/* Relay live stats */}
      {relay && (relay.intents.open > 0 || Object.keys(relay.makers).length > 0) && (
        <div className="pixel-border bg-navy-900 p-4">
          <p className="font-pixel text-[10px] text-pixel-cyan uppercase mb-3">Live Relay</p>
          <div className="flex gap-4">
            {relay.intents.open > 0 && (
              <span className="font-pixel text-[8px] text-amber-400">
                {relay.intents.open} OPEN INTENT{relay.intents.open !== 1 ? "S" : ""}
              </span>
            )}
          </div>
        </div>
      )}

      {/* Per-chain breakdown */}
      {UI_CHAINS.map((chain) => {
        const chainStats = onChain.chains[chain.chainId];
        const relayMakers = relay?.makers[String(chain.chainId)];

        if (!chainStats) return null;

        return (
          <div key={chain.chainId} className="pixel-border bg-navy-900 p-4 space-y-3">
            <div className="flex items-center justify-between">
              <p className="font-pixel text-[10px] text-pixel-cyan uppercase">
                {chain.name}
              </p>
              <div className="flex items-center gap-3">
                {relayMakers && relayMakers.count > 0 && (
                  <span className="font-pixel text-[8px] text-pixel-green flex items-center gap-1">
                    <span className="w-1.5 h-1.5 bg-pixel-green inline-block" />
                    {relayMakers.count} ONLINE
                  </span>
                )}
              </div>
            </div>

            {/* Chain metrics */}
            <div className="grid grid-cols-3 gap-2">
              <div>
                <p className="font-pixel text-[7px] text-teal-600 uppercase">Orders</p>
                <p className="font-pixel text-xs text-pixel-cyan">{chainStats.orderCount}</p>
              </div>
              <div>
                <p className="font-pixel text-[7px] text-teal-600 uppercase">Settled</p>
                <p className="font-pixel text-xs text-pixel-green">{chainStats.settledCount}</p>
              </div>
              <div>
                <p className="font-pixel text-[7px] text-teal-600 uppercase">Volume</p>
                <p className="font-pixel text-xs text-pixel-cyan">{formatUsdc(chainStats.volume)}</p>
              </div>
            </div>

            {/* Makers on this chain */}
            {chainStats.makers.length > 0 ? (
              <div className="space-y-1">
                <p className="font-pixel text-[7px] text-teal-600 uppercase">
                  Staked Makers ({chainStats.makers.length})
                </p>
                {chainStats.makers.map((maker) => (
                  <div
                    key={maker.address}
                    className="bg-navy-800 border-2 border-navy-600 px-3 py-2 flex items-center justify-between"
                  >
                    <CopyableAddress
                      address={maker.address}
                      className="font-mono text-[10px] text-teal-400"
                    />
                    <div className="flex items-center gap-2">
                      <span className="font-pixel text-[8px] text-pixel-cyan">
                        {formatUsdc(maker.stakedAmount)}
                      </span>
                      <span className={`w-1.5 h-1.5 inline-block ${maker.isActive ? "bg-pixel-green" : "bg-navy-600"}`} />
                    </div>
                  </div>
                ))}
              </div>
            ) : (
              <p className="font-pixel text-[8px] text-teal-600">NO STAKED MAKERS</p>
            )}
          </div>
        );
      })}
    </div>
  );
}
