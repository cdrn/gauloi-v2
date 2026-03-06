"use client";

import { SUPPORTED_TOKENS } from "@gauloi/common";
import { TokenIcon } from "./icons";

interface TokenSelectorProps {
  value: string;
  onChange: (symbol: string) => void;
}

export function TokenSelector({ value, onChange }: TokenSelectorProps) {
  return (
    <div className="relative">
      <div className="absolute left-2 top-1/2 -translate-y-1/2 pointer-events-none">
        <TokenIcon symbol={value} size={14} />
      </div>
      <select
        value={value}
        onChange={(e) => onChange(e.target.value)}
        className="pixel-input text-sm font-pixel text-[10px] text-pixel-cyan pl-7 pr-2"
      >
        {Object.entries(SUPPORTED_TOKENS).map(([symbol]) => (
          <option key={symbol} value={symbol}>
            {symbol}
          </option>
        ))}
      </select>
    </div>
  );
}
