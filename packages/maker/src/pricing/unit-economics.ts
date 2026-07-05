/**
 * Maker unit economics — the minimum viable spread for a corridor + trade size.
 *
 * A maker's spread must recover three costs:
 *   1. gas       — FIXED per trade, so its bps cost falls as trade size grows
 *   2. capital   — cost of fronting destination liquidity for the settlement
 *                  window; a flat bps (rate × time), independent of size
 *   3. risk      — counterparty/compliance + chain-pair finality, a flat bps
 *
 * The only size-dependent term is gas, so the min-spread curve is a hyperbola
 * in trade size that asymptotes to (capitalBps + riskBps) as size → ∞. That
 * asymptote is the corridor's structural floor; the gas tail is what makes
 * small trades uncompetitive.
 *
 * Gas units are the measured v0.2 medians (forge --gas-report). See README.
 */

export const SECONDS_PER_YEAR = 31_536_000;

/** Measured per-function gas (median, isolated calls) */
export const GAS_UNITS = {
  executeOrder: 200_000, // source
  submitFill: 67_000, // source
  settleStandalone: 62_000, // source
  settleBatched: 25_000, // source, amortised in a same-maker batch
  fill: 88_000, // destination (FillRegistry)
} as const;

export interface ChainGasProfile {
  name: string;
  gasPriceGwei: number; // typical gas price
  nativePriceUsd: number; // USD price of the gas token (ETH)
}

export interface CorridorProfile {
  source: ChainGasProfile;
  dest: ChainGasProfile;
  settlementWindowSec: number; // dispute/settlement window on this corridor
  batchedSettlement?: boolean; // maker settles in same-maker batches (default true)
  /**
   * Seconds the maker's capital is locked before it can be recycled. Defaults
   * to the settlement window (repayment latency). Set higher to include
   * cross-chain rebalancing time if the maker can't immediately reuse funds.
   */
  capitalLockSec?: number;
}

export interface MakerCostParams {
  costOfCapitalApr: number; // e.g. 0.10 for 10%/yr
  riskBps: number; // counterparty/compliance + finality premium, in bps
  marginBps: number; // target profit on top of breakeven
}

export interface Economics {
  tradeSizeUsd: number;
  gasCostUsd: number;
  capitalCostUsd: number;
  // bps breakdown
  gasBps: number;
  capitalBps: number;
  riskBps: number;
  breakevenBps: number; // gas + capital + risk (below this, the maker loses money)
  quoteBps: number; // breakeven + margin (what the maker should quote)
  floorBps: number; // capital + risk — the asymptote as size → ∞
}

/** Total source-chain gas per trade for the maker (execute + submit + settle) */
export function sourceGasUnits(batched: boolean): number {
  const settle = batched ? GAS_UNITS.settleBatched : GAS_UNITS.settleStandalone;
  return GAS_UNITS.executeOrder + GAS_UNITS.submitFill + settle;
}

/** USD gas cost for `gasUnits` on a chain */
export function gasCostUsd(gasUnits: number, chain: ChainGasProfile): number {
  const ethPerGas = gasUnits * chain.gasPriceGwei * 1e-9; // gwei → ETH
  return ethPerGas * chain.nativePriceUsd;
}

/** Flat bps cost of capital for the lock duration (independent of trade size) */
export function capitalBps(corridor: CorridorProfile, params: MakerCostParams): number {
  const lockSec = corridor.capitalLockSec ?? corridor.settlementWindowSec;
  return params.costOfCapitalApr * (lockSec / SECONDS_PER_YEAR) * 10_000;
}

/** Full economics for one corridor + trade size */
export function computeEconomics(
  corridor: CorridorProfile,
  params: MakerCostParams,
  tradeSizeUsd: number,
): Economics {
  const batched = corridor.batchedSettlement ?? true;

  const srcGas = gasCostUsd(sourceGasUnits(batched), corridor.source);
  const dstGas = gasCostUsd(GAS_UNITS.fill, corridor.dest);
  const totalGasUsd = srcGas + dstGas;

  const capBps = capitalBps(corridor, params);
  const capitalCostUsd = (capBps / 10_000) * tradeSizeUsd;

  const gasBps = (totalGasUsd / tradeSizeUsd) * 10_000;
  const floorBps = capBps + params.riskBps;
  const breakevenBps = gasBps + floorBps;

  return {
    tradeSizeUsd,
    gasCostUsd: totalGasUsd,
    capitalCostUsd,
    gasBps,
    capitalBps: capBps,
    riskBps: params.riskBps,
    breakevenBps,
    quoteBps: breakevenBps + params.marginBps,
    floorBps,
  };
}

/**
 * Smallest trade size (USD) at which the maker can quote at or below a
 * competitor's spread and still clear breakeven + margin. Returns Infinity if
 * the corridor's floor alone already exceeds the competitor (never competitive
 * at any size), or 0 if competitive even as size → 0.
 */
export function minCompetitiveSizeUsd(
  corridor: CorridorProfile,
  params: MakerCostParams,
  competitorBps: number,
): number {
  const batched = corridor.batchedSettlement ?? true;
  const totalGasUsd =
    gasCostUsd(sourceGasUnits(batched), corridor.source) + gasCostUsd(GAS_UNITS.fill, corridor.dest);

  // Need: gasBps(size) + floorBps + marginBps <= competitorBps
  // gasBps(size) = totalGasUsd / size * 1e4  →  size >= totalGasUsd*1e4 / headroom
  const headroom = competitorBps - (capitalBps(corridor, params) + params.riskBps) - params.marginBps;
  if (headroom <= 0) return Infinity; // floor+margin already above competitor
  return (totalGasUsd * 10_000) / headroom;
}

/** Sweep trade sizes and return economics at each — the frontier */
export function spreadFrontier(
  corridor: CorridorProfile,
  params: MakerCostParams,
  sizesUsd: number[],
): Economics[] {
  return sizesUsd.map((s) => computeEconomics(corridor, params, s));
}

// --- Chain presets (edit gas price / ETH to taste) ---

export const ETH_MAINNET = (gasPriceGwei = 15, ethUsd = 3_000): ChainGasProfile => ({
  name: "Ethereum",
  gasPriceGwei,
  nativePriceUsd: ethUsd,
});

export const ARBITRUM = (gasPriceGwei = 0.01, ethUsd = 3_000): ChainGasProfile => ({
  name: "Arbitrum",
  gasPriceGwei,
  nativePriceUsd: ethUsd,
});

export const BASE = (gasPriceGwei = 0.02, ethUsd = 3_000): ChainGasProfile => ({
  name: "Base",
  gasPriceGwei,
  nativePriceUsd: ethUsd,
});
