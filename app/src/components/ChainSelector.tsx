"use client";

import { UI_CHAINS } from "@/config/chains";

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
      <label className="block font-pixel text-[8px] text-teal-600 uppercase tracking-widest mb-2">{label}</label>
      <select
        value={value ?? ""}
        onChange={(e) => onChange(Number(e.target.value))}
        className="w-full pixel-input text-sm"
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
