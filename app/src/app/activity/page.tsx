"use client";

import { IntentStatus } from "@/components/IntentStatus";
import { useEffect, useState } from "react";
import Link from "next/link";

interface StoredIntent {
  intentId: string;
  inputAmount: string;
  sourceChainId: number;
  destChainId: number;
  timestamp: number;
}

export default function ActivityPage() {
  const [intents, setIntents] = useState<StoredIntent[]>([]);

  // Load from localStorage and refresh periodically
  useEffect(() => {
    const load = () => {
      const stored = localStorage.getItem("gauloi_intents");
      if (stored) {
        setIntents(JSON.parse(stored));
      }
    };

    load();
    const interval = setInterval(load, 5000);
    return () => clearInterval(interval);
  }, []);

  if (intents.length === 0) {
    return (
      <div className="text-center py-20">
        <p className="text-lg text-gray-400">No swaps yet</p>
        <p className="text-sm text-gray-600 mt-2">
          Your swap history will appear here after your first swap.
        </p>
        <Link
          href="/"
          className="inline-block mt-6 text-sm text-white bg-gray-800 px-4 py-2 rounded-lg hover:bg-gray-700 transition-colors"
        >
          Make a swap
        </Link>
      </div>
    );
  }

  return (
    <div className="space-y-3">
      <div className="flex justify-between items-center mb-4">
        <h2 className="text-lg font-semibold">Your Swaps</h2>
        <span className="text-xs text-gray-600">{intents.length} total</span>
      </div>
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
