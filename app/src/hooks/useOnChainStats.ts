import { useEffect, useState } from "react";
import { usePublicClient } from "wagmi";
import { GauloiStakingAbi, GauloiEscrowAbi, GauloiDisputesAbi } from "@gauloi/common";
import { UI_CHAINS } from "@/config/chains";

// Approximate blocks per day: Sepolia ~7200, Arb Sepolia ~86400
// Use conservative estimates to avoid underfetching
const BLOCKS_7D: Record<number, bigint> = {
  11155111: 50_400n,  // Sepolia: ~7200/day * 7
  421614: 605_000n,   // Arb Sepolia: ~86400/day * 7
};
const DEFAULT_BLOCKS_7D = 50_400n;

// Max block range per eth_getLogs request — public RPCs reject large ranges
const MAX_LOG_RANGE: Record<number, bigint> = {
  11155111: 10_000n,   // Sepolia: conservative for public RPCs
  421614: 100_000n,    // Arb Sepolia: higher block rate, RPCs handle more
};
const DEFAULT_MAX_LOG_RANGE = 10_000n;

export interface MakerStake {
  address: string;
  stakedAmount: string;
  activeExposure: string;
  availableCapacity: string;
  isActive: boolean;
}

export interface ChainOnChainStats {
  makers: MakerStake[];
  totalStaked: string;
  orderCount: number;
  settledCount: number;
  disputeCount: number;
  volume: string;
  params: {
    settlementWindow: number;
    commitmentTimeout: number;
    minStake: string;
    cooldownPeriod: number;
    disputeResolutionWindow: number;
  };
}

export interface OnChainStats {
  chains: Record<number, ChainOnChainStats>;
  loading: boolean;
}

async function fetchChainStats(
  publicClient: any,
  chainId: number,
  stakingAddress: `0x${string}`,
  escrowAddress: `0x${string}`,
  disputesAddress: `0x${string}`,
): Promise<ChainOnChainStats> {
  // Get current block and compute 7-day lookback
  const currentBlock = await publicClient.getBlockNumber();
  const lookback = BLOCKS_7D[chainId] ?? DEFAULT_BLOCKS_7D;
  const fromBlock = currentBlock > lookback ? currentBlock - lookback : 0n;

  // Staked events use all-time to discover makers (stakes may be older than 7d)
  // but we cap to a reasonable range to avoid RPC limits
  const stakedFromBlock = currentBlock > lookback * 4n ? currentBlock - lookback * 4n : 0n;

  // Paginated event fetcher — splits large block ranges into RPC-safe chunks
  const chunkSize = MAX_LOG_RANGE[chainId] ?? DEFAULT_MAX_LOG_RANGE;
  const fetchEvents = async (
    opts: { address: `0x${string}`; abi: any; eventName: string },
    from: bigint,
    to: bigint,
  ) => {
    if (to - from <= chunkSize) {
      try {
        return await publicClient.getContractEvents({ ...opts, fromBlock: from, toBlock: to });
      } catch {
        return [];
      }
    }
    const chunks: Promise<any[]>[] = [];
    for (let start = from; start <= to; start += chunkSize + 1n) {
      const end = start + chunkSize > to ? to : start + chunkSize;
      chunks.push(
        publicClient.getContractEvents({ ...opts, fromBlock: start, toBlock: end }).catch(() => []),
      );
    }
    return (await Promise.all(chunks)).flat();
  };

  // Fetch events and protocol params in parallel
  const [stakedLogs, orderLogs, settledLogs, disputeLogs, settlementWindow, commitmentTimeout, minStake, cooldownPeriod, disputeResolutionWindow] = await Promise.all([
    fetchEvents(
      { address: stakingAddress, abi: GauloiStakingAbi, eventName: "Staked" },
      stakedFromBlock, currentBlock,
    ),
    fetchEvents(
      { address: escrowAddress, abi: GauloiEscrowAbi, eventName: "OrderExecuted" },
      fromBlock, currentBlock,
    ),
    fetchEvents(
      { address: escrowAddress, abi: GauloiEscrowAbi, eventName: "IntentSettled" },
      fromBlock, currentBlock,
    ),
    fetchEvents(
      { address: disputesAddress, abi: GauloiDisputesAbi, eventName: "DisputeRaised" },
      fromBlock, currentBlock,
    ),
    publicClient.readContract({
      address: escrowAddress,
      abi: GauloiEscrowAbi,
      functionName: "settlementWindow",
    }),
    publicClient.readContract({
      address: escrowAddress,
      abi: GauloiEscrowAbi,
      functionName: "commitmentTimeout",
    }),
    publicClient.readContract({
      address: stakingAddress,
      abi: GauloiStakingAbi,
      functionName: "minStake",
    }),
    publicClient.readContract({
      address: stakingAddress,
      abi: GauloiStakingAbi,
      functionName: "cooldownPeriod",
    }),
    publicClient.readContract({
      address: disputesAddress,
      abi: GauloiDisputesAbi,
      functionName: "disputeResolutionWindow",
    }),
  ]);

  // Deduplicate maker addresses from staked events
  const seen = new Set<string>();
  for (const log of stakedLogs) {
    seen.add((log as any).args.maker as string);
  }
  const makerAddresses = Array.from(seen);

  // Fetch current on-chain state for each discovered maker
  const makers: MakerStake[] = [];
  let totalStaked = 0n;

  if (makerAddresses.length > 0) {
    const makerInfos = await Promise.all(
      makerAddresses.map((addr) =>
        publicClient.readContract({
          address: stakingAddress,
          abi: GauloiStakingAbi,
          functionName: "getMakerInfo",
          args: [addr],
        }),
      ),
    );

    for (let i = 0; i < makerAddresses.length; i++) {
      const info = makerInfos[i] as any;
      const stakedAmount = info.stakedAmount ?? info[0] ?? 0n;
      const activeExposure = info.activeExposure ?? info[1] ?? 0n;
      const isActive = info.isActive ?? info[4] ?? false;
      const capacity = stakedAmount > activeExposure ? stakedAmount - activeExposure : 0n;

      if (stakedAmount > 0n) {
        makers.push({
          address: makerAddresses[i],
          stakedAmount: stakedAmount.toString(),
          activeExposure: activeExposure.toString(),
          availableCapacity: capacity.toString(),
          isActive,
        });
        totalStaked += stakedAmount;
      }
    }
  }

  // Sum volume from order events
  let volume = 0n;
  for (const log of orderLogs) {
    volume += (log as any).args.inputAmount ?? 0n;
  }

  return {
    makers,
    totalStaked: totalStaked.toString(),
    orderCount: orderLogs.length,
    settledCount: settledLogs.length,
    disputeCount: disputeLogs.length,
    volume: volume.toString(),
    params: {
      settlementWindow: Number(settlementWindow),
      commitmentTimeout: Number(commitmentTimeout),
      minStake: (minStake as bigint).toString(),
      cooldownPeriod: Number(cooldownPeriod),
      disputeResolutionWindow: Number(disputeResolutionWindow),
    },
  };
}

export function useOnChainStats(intervalMs = 60_000): OnChainStats {
  const [stats, setStats] = useState<OnChainStats>({
    chains: {},
    loading: true,
  });

  // Get a public client for each chain
  const clients = UI_CHAINS.map((chain) => ({
    chain,
    // eslint-disable-next-line react-hooks/rules-of-hooks
    client: usePublicClient({ chainId: chain.chainId }),
  }));

  useEffect(() => {
    let active = true;

    const load = async () => {
      const results: Record<number, ChainOnChainStats> = {};

      await Promise.all(
        clients.map(async ({ chain, client }) => {
          if (!client) return;
          try {
            results[chain.chainId] = await fetchChainStats(
              client,
              chain.chainId,
              chain.stakingAddress,
              chain.escrowAddress,
              chain.disputesAddress,
            );
          } catch (err) {
            console.error(`Failed to fetch on-chain stats for ${chain.name}:`, err);
          }
        }),
      );

      if (active) {
        setStats({ chains: results, loading: false });
      }
    };

    load();
    const id = setInterval(load, intervalMs);
    return () => {
      active = false;
      clearInterval(id);
    };
  }, [intervalMs]);

  return stats;
}
