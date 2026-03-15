"use client";

import { useNetworkStats } from "@/hooks/useNetworkStats";
import { useOnChainStats } from "@/hooks/useOnChainStats";
import { UI_CHAINS } from "@/config/chains";
import { formatUnits } from "viem";
import { CopyableAddress } from "@/components/CopyableAddress";

function formatUsdc(raw: string): string {
  if (raw === "0") return "0";
  return Number(formatUnits(BigInt(raw), 6)).toLocaleString(undefined, {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });
}

function formatDuration(seconds: number): string {
  if (seconds >= 3600) {
    const h = Math.floor(seconds / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    return m > 0 ? `${h}h ${m}m` : `${h}h`;
  }
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  return m > 0 ? (s > 0 ? `${m}m ${s}s` : `${m}m`) : `${s}s`;
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
  let totalDisputes = 0;
  let totalVolume = 0n;
  let totalStaked = 0n;

  for (const chainStats of Object.values(onChain.chains)) {
    totalOrders += chainStats.orderCount;
    totalSettled += chainStats.settledCount;
    totalDisputes += chainStats.disputeCount;
    if (chainStats.volume !== "0") totalVolume += BigInt(chainStats.volume);
    if (chainStats.totalStaked !== "0") totalStaked += BigInt(chainStats.totalStaked);
  }

  // Count total online makers from relay
  let totalOnlineMakers = 0;
  if (relay) {
    for (const chain of Object.values(relay.makers)) {
      totalOnlineMakers += chain.count;
    }
  }

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <h2 className="font-pixel text-sm text-pixel-cyan">NETWORK STATS</h2>
        <span className="font-pixel text-[8px] text-teal-600">LAST 7 DAYS</span>
      </div>

      {/* On-chain aggregate stats */}
      <div className="grid grid-cols-2 gap-3">
        <StatCard label="Orders" value={totalOrders} />
        <StatCard label="Settled" value={totalSettled} color="text-pixel-green" />
        <StatCard label="Volume (USDC)" value={formatUsdc(totalVolume.toString())} />
        <StatCard label="Total Staked" value={formatUsdc(totalStaked.toString())} />
      </div>

      {/* Relay status — always visible */}
      <div className="pixel-border bg-navy-900 p-4">
        <p className="font-pixel text-[10px] text-pixel-cyan uppercase mb-3">Live Relay</p>
        <div className="flex gap-4 flex-wrap">
          <span className={`font-pixel text-[8px] flex items-center gap-1 ${relay ? "text-pixel-green" : "text-teal-600"}`}>
            <span className={`w-1.5 h-1.5 inline-block ${relay ? "bg-pixel-green" : "bg-navy-600"}`} />
            {relay ? "CONNECTED" : "DISCONNECTED"}
          </span>
          {relay && (
            <>
              <span className="font-pixel text-[8px] text-teal-400">
                {totalOnlineMakers} MAKER{totalOnlineMakers !== 1 ? "S" : ""} ONLINE
              </span>
              {relay.intents.open > 0 && (
                <span className="font-pixel text-[8px] text-amber-400">
                  {relay.intents.open} OPEN INTENT{relay.intents.open !== 1 ? "S" : ""}
                </span>
              )}
              {totalDisputes > 0 && (
                <span className="font-pixel text-[8px] text-pixel-red">
                  {totalDisputes} DISPUTE{totalDisputes !== 1 ? "S" : ""}
                </span>
              )}
            </>
          )}
        </div>
      </div>

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
            <div className="grid grid-cols-4 gap-2">
              <div>
                <p className="font-pixel text-[7px] text-teal-600 uppercase">Orders</p>
                <p className="font-pixel text-xs text-pixel-cyan">{chainStats.orderCount}</p>
              </div>
              <div>
                <p className="font-pixel text-[7px] text-teal-600 uppercase">Settled</p>
                <p className="font-pixel text-xs text-pixel-green">{chainStats.settledCount}</p>
              </div>
              <div>
                <p className="font-pixel text-[7px] text-teal-600 uppercase">Disputes</p>
                <p className={`font-pixel text-xs ${chainStats.disputeCount > 0 ? "text-pixel-red" : "text-teal-600"}`}>{chainStats.disputeCount}</p>
              </div>
              <div>
                <p className="font-pixel text-[7px] text-teal-600 uppercase">Volume</p>
                <p className="font-pixel text-xs text-pixel-cyan">{formatUsdc(chainStats.volume)}</p>
              </div>
            </div>

            {/* Protocol parameters */}
            <div className="bg-navy-800 border-2 border-navy-600 p-3">
              <p className="font-pixel text-[7px] text-teal-600 uppercase mb-2">Protocol Parameters</p>
              <div className="grid grid-cols-2 gap-x-4 gap-y-1">
                <div className="flex justify-between">
                  <span className="font-pixel text-[7px] text-teal-600">Settlement</span>
                  <span className="font-pixel text-[7px] text-teal-400">{formatDuration(chainStats.params.settlementWindow)}</span>
                </div>
                <div className="flex justify-between">
                  <span className="font-pixel text-[7px] text-teal-600">Commitment</span>
                  <span className="font-pixel text-[7px] text-teal-400">{formatDuration(chainStats.params.commitmentTimeout)}</span>
                </div>
                <div className="flex justify-between">
                  <span className="font-pixel text-[7px] text-teal-600">Dispute Window</span>
                  <span className="font-pixel text-[7px] text-teal-400">{formatDuration(chainStats.params.disputeResolutionWindow)}</span>
                </div>
                <div className="flex justify-between">
                  <span className="font-pixel text-[7px] text-teal-600">Cooldown</span>
                  <span className="font-pixel text-[7px] text-teal-400">{formatDuration(chainStats.params.cooldownPeriod)}</span>
                </div>
                <div className="flex justify-between">
                  <span className="font-pixel text-[7px] text-teal-600">Min Stake</span>
                  <span className="font-pixel text-[7px] text-teal-400">{formatUsdc(chainStats.params.minStake)} USDC</span>
                </div>
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
                    className="bg-navy-800 border-2 border-navy-600 px-3 py-2 space-y-1"
                  >
                    <div className="flex items-center justify-between">
                      <CopyableAddress
                        address={maker.address}
                        className="font-mono text-[10px] text-teal-400"
                      />
                      <span className={`font-pixel text-[7px] px-1.5 py-0.5 border ${
                        maker.isActive
                          ? "text-pixel-green border-pixel-green"
                          : "text-pixel-red border-pixel-red"
                      }`}>
                        {maker.isActive ? "ACTIVE" : "INACTIVE"}
                      </span>
                    </div>
                    <div className="grid grid-cols-3 gap-2">
                      <div>
                        <p className="font-pixel text-[6px] text-teal-600 uppercase">Staked</p>
                        <p className="font-pixel text-[8px] text-pixel-cyan">{formatUsdc(maker.stakedAmount)}</p>
                      </div>
                      <div>
                        <p className="font-pixel text-[6px] text-teal-600 uppercase">Exposure</p>
                        <p className="font-pixel text-[8px] text-pixel-cyan">{formatUsdc(maker.activeExposure)}</p>
                      </div>
                      <div>
                        <p className="font-pixel text-[6px] text-teal-600 uppercase">Capacity</p>
                        <p className="font-pixel text-[8px] text-pixel-green">{formatUsdc(maker.availableCapacity)}</p>
                      </div>
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
