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
        <p className="font-pixel text-sm text-teal-600">NO SWAPS YET</p>
        <p className="text-sm text-navy-600 mt-4">
          Your swap history will appear here.
        </p>
        <Link
          href="/"
          className="inline-block mt-6 pixel-btn"
        >
          MAKE A SWAP
        </Link>
      </div>
    );
  }

  return (
    <div className="space-y-3">
      <div className="flex justify-between items-center mb-4">
        <h2 className="font-pixel text-sm text-pixel-cyan">ACTIVITY</h2>
        <span className="font-pixel text-[8px] text-teal-600">{intents.length} TOTAL</span>
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
