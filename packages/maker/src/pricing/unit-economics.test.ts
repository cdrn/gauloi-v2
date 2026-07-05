import { describe, it, expect } from "vitest";
import {
  computeEconomics,
  minCompetitiveSizeUsd,
  capitalBps,
  spreadFrontier,
  sourceGasUnits,
  gasCostUsd,
  GAS_UNITS,
  ETH_MAINNET,
  ARBITRUM,
  type CorridorProfile,
  type MakerCostParams,
} from "./unit-economics.js";

const params: MakerCostParams = {
  costOfCapitalApr: 0.1, // 10%/yr
  riskBps: 1,
  marginBps: 1,
};

// Ethereum L1 source → Arbitrum dest, 30-min window
const ethToArb: CorridorProfile = {
  source: ETH_MAINNET(15, 3_000),
  dest: ARBITRUM(0.01, 3_000),
  settlementWindowSec: 30 * 60,
};

// Arbitrum source → Base dest, 2-min window (both L2)
const l2ToL2: CorridorProfile = {
  source: ARBITRUM(0.01, 3_000),
  dest: ARBITRUM(0.02, 3_000),
  settlementWindowSec: 2 * 60,
};

describe("gas cost", () => {
  it("source gas = execute + submit + settle (batched by default)", () => {
    expect(sourceGasUnits(true)).toBe(
      GAS_UNITS.executeOrder + GAS_UNITS.submitFill + GAS_UNITS.settleBatched,
    );
    expect(sourceGasUnits(false)).toBe(
      GAS_UNITS.executeOrder + GAS_UNITS.submitFill + GAS_UNITS.settleStandalone,
    );
  });

  it("converts gas units to USD via gwei × ETH price", () => {
    // 292k gas × 15 gwei × 1e-9 ETH/gwei × $3000 = $13.14
    const usd = gasCostUsd(292_000, ETH_MAINNET(15, 3_000));
    expect(usd).toBeCloseTo(292_000 * 15e-9 * 3_000, 6);
    expect(usd).toBeCloseTo(13.14, 2);
  });
});

describe("capital cost", () => {
  it("is a flat bps independent of trade size (rate × time)", () => {
    // 10%/yr for 30 min = 0.10 * (1800/31536000) * 1e4 bps
    const bps = capitalBps(ethToArb, params);
    expect(bps).toBeCloseTo(0.1 * (1800 / 31_536_000) * 10_000, 9);
    expect(bps).toBeCloseTo(0.057, 3); // ~0.057 bps — tiny for a 30-min window
  });

  it("shrinks with a shorter window — the per-corridor-window lever", () => {
    const short = capitalBps({ ...ethToArb, settlementWindowSec: 120 }, params);
    const long = capitalBps({ ...ethToArb, settlementWindowSec: 1800 }, params);
    expect(short).toBeLessThan(long);
    expect(long / short).toBeCloseTo(15, 1); // 1800/120 = 15×
  });
});

describe("computeEconomics", () => {
  it("gas dominates at small size, vanishes at large size", () => {
    const small = computeEconomics(ethToArb, params, 1_000);
    const large = computeEconomics(ethToArb, params, 1_000_000);

    // Same absolute gas cost, wildly different bps
    expect(small.gasCostUsd).toBeCloseTo(large.gasCostUsd, 6);
    expect(small.gasBps).toBeGreaterThan(100); // >100 bps on a $1k L1-source trade
    expect(large.gasBps).toBeLessThan(1); // <1 bp on a $1M trade

    // Breakeven asymptotes toward the floor: the entire gap IS the gas tail,
    // which keeps shrinking with size (0.13bp at $1M, 0.013bp at $10M)
    expect(large.breakevenBps - large.floorBps).toBeCloseTo(large.gasBps, 9);
    const huge = computeEconomics(ethToArb, params, 10_000_000);
    expect(huge.breakevenBps - huge.floorBps).toBeLessThan(0.05);
  });

  it("floor = capital + risk, and breakeven >= floor always", () => {
    const e = computeEconomics(ethToArb, params, 500_000);
    expect(e.floorBps).toBeCloseTo(e.capitalBps + e.riskBps, 9);
    expect(e.breakevenBps).toBeGreaterThanOrEqual(e.floorBps);
    expect(e.quoteBps).toBeCloseTo(e.breakevenBps + params.marginBps, 9);
  });

  it("L2-source corridor is competitive at far smaller sizes than L1-source", () => {
    const l1 = computeEconomics(ethToArb, params, 5_000);
    const l2 = computeEconomics(l2ToL2, params, 5_000);
    // Same $5k trade: L1 source gas is ~100× the L2 source gas cost
    expect(l1.gasBps).toBeGreaterThan(l2.gasBps * 50);
    expect(l2.quoteBps).toBeLessThan(3); // sub-3bp quote viable on a $5k L2 trade
  });
});

describe("minCompetitiveSizeUsd", () => {
  it("finds the size where we can beat a competitor's spread", () => {
    // Against a 5bp competitor on the L1-source corridor
    const minSize = minCompetitiveSizeUsd(ethToArb, params, 5);
    expect(minSize).toBeGreaterThan(10_000);
    expect(minSize).toBeLessThan(100_000);

    // Just above that size we clear; just below we don't
    const above = computeEconomics(ethToArb, params, minSize * 1.01);
    const below = computeEconomics(ethToArb, params, minSize * 0.99);
    expect(above.quoteBps).toBeLessThanOrEqual(5);
    expect(below.quoteBps).toBeGreaterThan(5);
  });

  it("returns Infinity when the floor alone exceeds the competitor", () => {
    const heavyRisk: MakerCostParams = { ...params, riskBps: 10 };
    // Competitor at 3bp, but our risk floor is already 10bp → never competitive
    expect(minCompetitiveSizeUsd(ethToArb, heavyRisk, 3)).toBe(Infinity);
  });

  it("L2 source collapses the min competitive size", () => {
    const l1Min = minCompetitiveSizeUsd(ethToArb, params, 5);
    const l2Min = minCompetitiveSizeUsd(l2ToL2, params, 5);
    expect(l2Min).toBeLessThan(l1Min / 50);
  });
});

describe("spreadFrontier", () => {
  it("returns economics per size, monotonically decreasing breakeven", () => {
    const sizes = [1_000, 10_000, 100_000, 1_000_000];
    const frontier = spreadFrontier(ethToArb, params, sizes);
    expect(frontier).toHaveLength(4);
    for (let i = 1; i < frontier.length; i++) {
      expect(frontier[i].breakevenBps).toBeLessThan(frontier[i - 1].breakevenBps);
    }
  });
});
