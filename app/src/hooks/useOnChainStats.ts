import { useEffect, useState } from "react";
import { usePublicClient } from "wagmi";
import { formatUnits } from "viem";
import { GauloiStakingAbi, GauloiEscrowAbi } from "@gauloi/common";
import { UI_CHAINS } from "@/config/chains";

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
  stakingAddress: `0x${string}`,
  escrowAddress: `0x${string}`,
): Promise<ChainOnChainStats> {
  // Fetch staked events to discover maker addresses
  const stakedLogs = await publicClient.getContractEvents({
    address: stakingAddress,
    abi: GauloiStakingAbi,
    eventName: "Staked",
    fromBlock: 0n,
  });

  // Deduplicate maker addresses from events
  const seen = new Set<string>();
  for (const log of stakedLogs) {
    seen.add((log as any).args.maker as string);
  }
  const makerAddresses = Array.from(seen);

  // Fetch current state for each maker
  const makers: MakerStake[] = [];
  let totalStaked = 0n;

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

  // Fetch order and settlement events
  const [orderLogs, settledLogs] = await Promise.all([
    publicClient.getContractEvents({
      address: escrowAddress,
      abi: GauloiEscrowAbi,
      eventName: "OrderExecuted",
      fromBlock: 0n,
    }),
    publicClient.getContractEvents({
      address: escrowAddress,
      abi: GauloiEscrowAbi,
      eventName: "IntentSettled",
      fromBlock: 0n,
    }),
  ]);

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

    const fetch = async () => {
      const results: Record<number, ChainOnChainStats> = {};

      await Promise.all(
        clients.map(async ({ chain, client }) => {
          if (!client) return;
          try {
            results[chain.chainId] = await fetchChainStats(
              client,
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

    fetch();
    const id = setInterval(fetch, intervalMs);
    return () => {
      active = false;
      clearInterval(id);
    };
  }, [intervalMs]);

  return stats;
}
