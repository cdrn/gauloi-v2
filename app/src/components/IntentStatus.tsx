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

const STATE_STYLES: Record<number, string> = {
  [IntentState.Committed]: "border-amber-400 text-amber-400",
  [IntentState.Filled]: "border-pixel-cyan text-pixel-cyan",
  [IntentState.Settled]: "border-pixel-green text-pixel-green",
  [IntentState.Disputed]: "border-pixel-red text-pixel-red",
  [IntentState.Expired]: "border-navy-600 text-teal-600",
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
    <div className="bg-navy-800 border-2 border-navy-600 p-4">
      <div className="flex justify-between items-start">
        <div>
          <p className="font-pixel text-[10px] text-pixel-cyan">{amount} USDC</p>
          <p className="text-xs text-teal-600 mt-2 font-mono">
            {sourceName} &rarr; {destName}
          </p>
          <p className="text-[10px] text-navy-600 mt-1 font-mono">
            {intentId.slice(0, 10)}...{intentId.slice(-8)}
          </p>
        </div>
        <div className="flex flex-col items-end gap-2">
          <span
            className={`font-pixel text-[8px] px-2 py-1 border-2 uppercase ${
              state !== null ? STATE_STYLES[state] ?? "border-navy-600 text-teal-600" : "border-navy-600 text-teal-600"
            }`}
          >
            {isLoading ? "..." : label}
          </span>
          <span className="text-[10px] text-navy-600 font-mono">
            {new Date(timestamp).toLocaleTimeString()}
          </span>
        </div>
      </div>
    </div>
  );
}
