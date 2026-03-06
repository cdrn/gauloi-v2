import { useEffect, useState } from "react";
import { usePublicClient } from "wagmi";
import { GauloiStakingAbi, GauloiEscrowAbi } from "@gauloi/common";
import { UI_CHAINS } from "@/config/chains";

// Approximate blocks per day: Sepolia ~7200, Arb Sepolia ~86400
// Use conservative estimates to avoid underfetching
const BLOCKS_7D: Record<number, bigint> = {
  11155111: 50_400n,  // Sepolia: ~7200/day * 7
  421614: 605_000n,   // Arb Sepolia: ~86400/day * 7
};
const DEFAULT_BLOCKS_7D = 50_400n;

export interface MakerStake {
  address: string;
  stakedAmount: string;
  isActive: boolean;
}

export interface ChainOnChainStats {
  makers: MakerStake[];
  totalStaked: string;
  orderCount: number;
  settledCount: number;
  volume: string;
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
): Promise<ChainOnChainStats> {
  // Get current block and compute 7-day lookback
  const currentBlock = await publicClient.getBlockNumber();
  const lookback = BLOCKS_7D[chainId] ?? DEFAULT_BLOCKS_7D;
  const fromBlock = currentBlock > lookback ? currentBlock - lookback : 0n;

  // Staked events use all-time to discover makers (stakes may be older than 7d)
  // but we cap to a reasonable range to avoid RPC limits
  const stakedFromBlock = currentBlock > lookback * 4n ? currentBlock - lookback * 4n : 0n;

  // Fetch events in parallel
  const [stakedLogs, orderLogs, settledLogs] = await Promise.all([
    publicClient.getContractEvents({
      address: stakingAddress,
      abi: GauloiStakingAbi,
      eventName: "Staked",
      fromBlock: stakedFromBlock,
    }),
    publicClient.getContractEvents({
      address: escrowAddress,
      abi: GauloiEscrowAbi,
      eventName: "OrderExecuted",
      fromBlock,
    }),
    publicClient.getContractEvents({
      address: escrowAddress,
      abi: GauloiEscrowAbi,
      eventName: "IntentSettled",
      fromBlock,
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
      const isActive = info.isActive ?? info[4] ?? false;

      if (stakedAmount > 0n) {
        makers.push({
          address: makerAddresses[i],
          stakedAmount: stakedAmount.toString(),
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
    volume: volume.toString(),
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
