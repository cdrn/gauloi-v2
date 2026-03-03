"use client";

import { useIntentStatus } from "@/hooks/useIntentStatus";
import { SUPPORTED_CHAINS, IntentState } from "@gauloi/common";

interface IntentStatusProps {
  intentId: `0x${string}`;
  inputAmount: string;
  sourceChainId: number;
  destChainId: number;
  timestamp: number;
}

const STATE_COLORS: Record<number, string> = {
  [IntentState.Committed]: "bg-yellow-900 text-yellow-300",
  [IntentState.Filled]: "bg-blue-900 text-blue-300",
  [IntentState.Settled]: "bg-green-900 text-green-300",
  [IntentState.Disputed]: "bg-red-900 text-red-300",
  [IntentState.Expired]: "bg-gray-800 text-gray-400",
};

export function IntentStatus({
  intentId,
  inputAmount,
  sourceChainId,
  destChainId,
  timestamp,
}: IntentStatusProps) {
  const escrowAddress = SUPPORTED_CHAINS[sourceChainId]?.escrowAddress;
  const { state, label, isLoading } = useIntentStatus(intentId, escrowAddress);

  const sourceName = SUPPORTED_CHAINS[sourceChainId]?.name ?? `Chain ${sourceChainId}`;
  const destName = SUPPORTED_CHAINS[destChainId]?.name ?? `Chain ${destChainId}`;
  const amount = (Number(inputAmount) / 1e6).toFixed(2);

  return (
    <div className="bg-gray-900 border border-gray-800 rounded-lg p-4">
      <div className="flex justify-between items-start">
        <div>
          <p className="text-sm font-medium">{amount} USDC</p>
          <p className="text-xs text-gray-500 mt-1">
            {sourceName} &rarr; {destName}
          </p>
          <p className="text-xs text-gray-600 mt-1 font-mono">
            {intentId.slice(0, 10)}...{intentId.slice(-8)}
          </p>
        </div>
        <div className="flex flex-col items-end gap-1">
          <span
            className={`text-xs px-2 py-0.5 rounded-full ${
              state !== null ? STATE_COLORS[state] ?? "bg-gray-800 text-gray-400" : "bg-gray-800 text-gray-500"
            }`}
          >
            {isLoading ? "..." : label}
          </span>
          <span className="text-xs text-gray-600">
            {new Date(timestamp).toLocaleTimeString()}
          </span>
        </div>
      </div>
    </div>
  );
}
