"use client";

export function Marquee() {
  const text = "CROSS-CHAIN STABLECOIN SETTLEMENT";
  const separator = " \u2605 ";
  // Repeat enough times to fill the screen and scroll seamlessly
  const repeated = Array(12).fill(text).join(separator) + separator;

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
