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

  const [taker, state, maker, commitmentDeadline, disputeWindowEnd, fillTxHash] =
    data as [string, number, string, number, number, string];

  return {
    state: state as IntentState,
    label: STATE_LABELS[state] ?? "Unknown",
    commitment: { taker, state, maker, commitmentDeadline, disputeWindowEnd, fillTxHash },
    isLoading,
  };
}
