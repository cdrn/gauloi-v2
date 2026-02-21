import type { ScreenResult } from "../compliance/screener.js";

export interface QuoterConfig {
  // Spread in basis points per risk tier
  spreads: {
    clean: number;   // e.g. 3 bps
    unknown: number;  // e.g. 15 bps
  };
  // Maximum fill size per intent
  maxFillSize: bigint;
}

const DEFAULT_CONFIG: QuoterConfig = {
  spreads: {
    clean: 3,
    unknown: 15,
  },
  maxFillSize: 100_000_000_000n, // 100k USDC (6 decimals)
};

export class Quoter {
  private config: QuoterConfig;

  constructor(config?: Partial<QuoterConfig>) {
    this.config = { ...DEFAULT_CONFIG, ...config };
  }

  /**
   * Calculate the output amount for a given input, applying the risk-based spread.
   * For stablecoin pairs this is approximately 1:1 minus the spread.
   */
  calculateOutputAmount(
    inputAmount: bigint,
    riskTier: ScreenResult["riskTier"],
  ): bigint | null {
    if (riskTier === "flagged") return null;
    if (inputAmount > this.config.maxFillSize) return null;

    const spreadBps = this.config.spreads[riskTier];
    // output = input * (10000 - spreadBps) / 10000
    const output = (inputAmount * BigInt(10_000 - spreadBps)) / 10_000n;
    return output;
  }

  getSpreadBps(riskTier: ScreenResult["riskTier"]): number | null {
    if (riskTier === "flagged") return null;
    return this.config.spreads[riskTier];
  }
}
