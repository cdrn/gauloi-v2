"use client";

import { UI_CHAINS } from "@/config/chains";
import type { ChainConfig } from "@gauloi/common";

interface ChainSelectorProps {
  label: string;
  value: number | null;
  onChange: (chainId: number) => void;
  exclude?: number | null;
}

export function ChainSelector({ label, value, onChange, exclude }: ChainSelectorProps) {
  const chains = UI_CHAINS.filter((c) => c.chainId !== exclude);

  return (
    <div>
      <label className="block text-xs text-gray-500 mb-1">{label}</label>
      <select
        value={value ?? ""}
        onChange={(e) => onChange(Number(e.target.value))}
        className="w-full bg-gray-800 border border-gray-700 rounded-lg px-3 py-2 text-sm focus:outline-none focus:border-gray-500"
      >
        <option value="" disabled>Select chain</option>
        {chains.map((chain) => (
          <option key={chain.chainId} value={chain.chainId}>
            {chain.name}
          </option>
        ))}
      </select>
    </div>
  );
}
