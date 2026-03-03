import { useReadContract } from "wagmi";
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
) {
  const { data, isLoading } = useReadContract({
    address: escrowAddress,
    abi: GauloiEscrowAbi,
    functionName: "getCommitment",
    args: intentId ? [intentId] : undefined,
    query: {
      enabled: !!intentId && !!escrowAddress,
      refetchInterval: 5000,
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

  return {
    state: commitment.state as IntentState,
    label: STATE_LABELS[commitment.state] ?? "Unknown",
    commitment,
    isLoading,
  };
}
