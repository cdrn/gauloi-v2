"use client";

import { IntentStatus } from "@/components/IntentStatus";
import { useEffect, useState } from "react";

interface StoredIntent {
  intentId: string;
  inputAmount: string;
  sourceChainId: number;
  destChainId: number;
  timestamp: number;
}

export default function ActivityPage() {
  const [intents, setIntents] = useState<StoredIntent[]>([]);

  useEffect(() => {
    const stored = localStorage.getItem("gauloi_intents");
    if (stored) {
      setIntents(JSON.parse(stored));
    }
  }, []);

  if (intents.length === 0) {
    return (
      <div className="text-center text-gray-500 py-20">
        <p className="text-lg">No swaps yet</p>
        <p className="text-sm mt-2">Your swap history will appear here</p>
      </div>
    );
  }

  return (
    <div className="space-y-3">
      <h2 className="text-lg font-semibold mb-4">Your Swaps</h2>
      {intents.map((intent) => (
        <IntentStatus
          key={intent.intentId}
          intentId={intent.intentId as `0x${string}`}
          inputAmount={intent.inputAmount}
          sourceChainId={intent.sourceChainId}
          destChainId={intent.destChainId}
          timestamp={intent.timestamp}
        />
      ))}
    </div>
  );
}
