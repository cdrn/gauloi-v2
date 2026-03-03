"use client";

interface Quote {
  intentId: string;
  maker: string;
  outputAmount: string;
  estimatedFillTime: number;
  expiry: number;
  signature: string;
}

interface QuoteListProps {
  quotes: Quote[];
  inputAmount: bigint;
  decimals: number;
  onSelect: (maker: string) => void;
}

function formatAmount(raw: string, decimals: number): string {
  const n = Number(raw) / 10 ** decimals;
  return n.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function truncateAddress(addr: string): string {
  return `${addr.slice(0, 6)}...${addr.slice(-4)}`;
}

export function QuoteList({ quotes, inputAmount, decimals, onSelect }: QuoteListProps) {
  if (quotes.length === 0) {
    return (
      <div className="text-center text-gray-500 py-6 text-sm">
        Waiting for maker quotes...
      </div>
    );
  }

  // Sort by output amount descending (best for taker first)
  const sorted = [...quotes].sort(
    (a, b) => Number(BigInt(b.outputAmount) - BigInt(a.outputAmount)),
  );

  return (
    <div className="space-y-2">
      <p className="text-xs text-gray-500">{quotes.length} quote{quotes.length > 1 ? "s" : ""} received</p>
      {sorted.map((quote, i) => {
        const spread = inputAmount > 0n
          ? ((Number(inputAmount) - Number(quote.outputAmount)) / Number(inputAmount)) * 10000
          : 0;

        return (
          <button
            key={`${quote.maker}-${i}`}
            onClick={() => onSelect(quote.maker)}
            className="w-full bg-gray-800 border border-gray-700 rounded-lg p-3 text-left hover:border-gray-500 transition-colors"
          >
            <div className="flex justify-between items-center">
              <div>
                <span className="text-sm font-medium">
                  {formatAmount(quote.outputAmount, decimals)}
                </span>
                <span className="text-xs text-gray-500 ml-2">
                  {spread.toFixed(1)} bps
                </span>
              </div>
              <div className="text-xs text-gray-500">
                {truncateAddress(quote.maker)} &middot; ~{quote.estimatedFillTime}s
              </div>
            </div>
          </button>
        );
      })}
    </div>
  );
}
