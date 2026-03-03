"use client";

export function Marquee() {
  const line1 = "CROSS-CHAIN STABLECOIN SETTLEMENT";
  const line2 = "ZERO GAS FOR TAKERS \u2022 INTENT-BASED \u2022 OPTIMISTIC SETTLEMENT";
  const separator = " \u2605 ";
  const combined = `${line1} ${separator} ${line2}`;
  const repeated = Array(10).fill(combined).join(separator) + separator;

  return (
    <div className="bg-teal-600 overflow-hidden whitespace-nowrap">
      <div className="animate-marquee inline-block">
        <span className="font-pixel text-[10px] text-navy-900 tracking-widest py-1.5 inline-block">
          {repeated}
        </span>
        <span className="font-pixel text-[10px] text-navy-900 tracking-widest py-1.5 inline-block">
          {repeated}
        </span>
      </div>
    </div>
  );
}
