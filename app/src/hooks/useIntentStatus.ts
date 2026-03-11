import { useReadContract } from "wagmi";
import { zeroAddress } from "viem";
import { GauloiEscrowAbi, IntentState } from "@gauloi/common";

const STATE_LABELS: Record<number, string> = {
  [IntentState.Committed]: "Committed",
  [IntentState.Filled]: "Filled",
  [IntentState.Settled]: "Settled",
  [IntentState.Disputed]: "Disputed",
  [IntentState.Expired]: "Expired",
};

export function useIntentStatus(
  intentId: `0x${string}` | undefined,
  escrowAddress: `0x${string}` | undefined,
  chainId?: number,
) {
  const { data, isLoading } = useReadContract({
    address: escrowAddress,
    abi: GauloiEscrowAbi,
    functionName: "getCommitment",
    args: intentId ? [intentId] : undefined,
    chainId,
    query: {
      enabled: !!intentId && !!escrowAddress,
      refetchInterval: 2000,
    },
  });

  if (!data || isLoading) {
    return { state: null, label: "Loading...", commitment: null, isLoading };
  }

  const commitment = data as unknown as {
    taker: string;
    state: number;
    maker: string;
    commitmentDeadline: number;
    disputeWindowEnd: number;
    fillTxHash: string;
  };

  // Empty commitment (not yet on-chain) has taker = zero address
  if (commitment.taker === zeroAddress) {
    return { state: null, label: "Pending...", commitment: null, isLoading };
  }

  return {
    state: commitment.state as IntentState,
    label: STATE_LABELS[commitment.state] ?? "Unknown",
    commitment,
    isLoading,
  };
}
