import { SUPPORTED_CHAINS, type ChainConfig } from "@gauloi/common";

// Re-export chain configs — contract addresses come from @gauloi/common
// RPC URLs come from NEXT_PUBLIC_ env vars at runtime via wagmi transports
export { SUPPORTED_CHAINS };
export type { ChainConfig };

// Chains we show in the UI
export const UI_CHAINS = [
  SUPPORTED_CHAINS[11155111]!, // Sepolia
  SUPPORTED_CHAINS[421614]!,   // Arbitrum Sepolia
] as const;

// For mainnet launch, swap to:
// export const UI_CHAINS = [
//   SUPPORTED_CHAINS[1]!,     // Ethereum
//   SUPPORTED_CHAINS[42161]!, // Arbitrum
// ] as const;
