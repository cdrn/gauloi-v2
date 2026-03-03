"use client";

import { SUPPORTED_TOKENS } from "@gauloi/common";

interface TokenSelectorProps {
  value: string;
  onChange: (symbol: string) => void;
}

export function TokenSelector({ value, onChange }: TokenSelectorProps) {
  return (
    <select
      value={value}
      onChange={(e) => onChange(e.target.value)}
      className="pixel-input text-sm font-pixel text-[10px] text-pixel-cyan"
    >
      {Object.entries(SUPPORTED_TOKENS).map(([symbol]) => (
        <option key={symbol} value={symbol}>
          {symbol}
        </option>
      ))}
    </select>
  );
}
