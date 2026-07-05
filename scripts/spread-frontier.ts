#!/usr/bin/env tsx
/**
 * Render the maker min-spread frontier per corridor, so you can see where gas
 * stops eating the spread before committing liquidity.
 *
 *   pnpm tsx scripts/spread-frontier.ts
 *   ETH_GWEI=30 ETH_USD=3500 COMPETITOR_BPS=5 pnpm tsx scripts/spread-frontier.ts
 */
import {
  computeEconomics,
  minCompetitiveSizeUsd,
  ETH_MAINNET,
  ARBITRUM,
  BASE,
  type CorridorProfile,
  type MakerCostParams,
} from "../packages/maker/src/pricing/unit-economics.js";

const ethGwei = Number(process.env.ETH_GWEI ?? 15);
const ethUsd = Number(process.env.ETH_USD ?? 3_000);
const competitorBps = Number(process.env.COMPETITOR_BPS ?? 5);

const params: MakerCostParams = {
  costOfCapitalApr: Number(process.env.COC_APR ?? 0.1),
  riskBps: Number(process.env.RISK_BPS ?? 1),
  marginBps: Number(process.env.MARGIN_BPS ?? 1),
};

const SIZES = [1_000, 10_000, 100_000, 1_000_000, 5_000_000];

const corridors: { label: string; corridor: CorridorProfile }[] = [
  {
    label: "Ethereum L1 → Arbitrum (30-min window)",
    corridor: { source: ETH_MAINNET(ethGwei, ethUsd), dest: ARBITRUM(0.01, ethUsd), settlementWindowSec: 1800 },
  },
  {
    label: "Ethereum L1 → Arbitrum (2-min window, provable)",
    corridor: { source: ETH_MAINNET(ethGwei, ethUsd), dest: ARBITRUM(0.01, ethUsd), settlementWindowSec: 120 },
  },
  {
    label: "Arbitrum → Base (2-min window, both L2)",
    corridor: { source: ARBITRUM(0.01, ethUsd), dest: BASE(0.02, ethUsd), settlementWindowSec: 120 },
  },
];

function fmtUsd(n: number): string {
  if (n >= 1_000_000) return `$${(n / 1_000_000).toFixed(0)}M`;
  if (n >= 1_000) return `$${(n / 1_000).toFixed(0)}k`;
  return `$${n.toFixed(0)}`;
}

function pad(s: string, w: number): string {
  return s.length >= w ? s : s + " ".repeat(w - s.length);
}
function padL(s: string, w: number): string {
  return s.length >= w ? s : " ".repeat(w - s.length) + s;
}

console.log(
  `\nMaker min-spread frontier   |   ETH ${ethGwei} gwei @ $${ethUsd}   |   ` +
    `cost-of-capital ${(params.costOfCapitalApr * 100).toFixed(0)}%/yr, ` +
    `risk ${params.riskBps}bp, margin ${params.marginBps}bp   |   competitor ${competitorBps}bp\n`,
);

for (const { label, corridor } of corridors) {
  const minSize = minCompetitiveSizeUsd(corridor, params, competitorBps);
  const minSizeStr = minSize === Infinity ? "never (floor > competitor)" : `${fmtUsd(minSize)}+`;
  console.log(`── ${label}`);
  console.log(`   gas/trade: ${fmtGas(corridor)}   ·   beats ${competitorBps}bp competitor above: ${minSizeStr}`);
  console.log(
    "   " +
      pad("size", 8) +
      padL("gas bp", 10) +
      padL("capital bp", 12) +
      padL("risk bp", 9) +
      padL("breakeven", 11) +
      padL("quote", 8) +
      padL("vs comp", 9),
  );
  for (const size of SIZES) {
    const e = computeEconomics(corridor, params, size);
    const beats = e.quoteBps <= competitorBps ? "win" : "lose";
    console.log(
      "   " +
        pad(fmtUsd(size), 8) +
        padL(e.gasBps.toFixed(2), 10) +
        padL(e.capitalBps.toFixed(3), 12) +
        padL(e.riskBps.toFixed(0), 9) +
        padL(e.breakevenBps.toFixed(2), 11) +
        padL(e.quoteBps.toFixed(2), 8) +
        padL(beats, 9),
    );
  }
  console.log("");
}

function fmtGas(corridor: CorridorProfile): string {
  const e = computeEconomics(corridor, params, 1_000_000);
  return `$${e.gasCostUsd.toFixed(2)}`;
}
