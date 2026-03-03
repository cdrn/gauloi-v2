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
      className="bg-gray-700 border border-gray-600 rounded-lg px-3 py-2 text-sm font-medium focus:outline-none focus:border-gray-500"
    >
      {Object.entries(SUPPORTED_TOKENS).map(([symbol]) => (
        <option key={symbol} value={symbol}>
          {symbol}
        </option>
      ))}
    </select>
  );
}
