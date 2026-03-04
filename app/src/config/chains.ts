import { SUPPORTED_CHAINS, type ChainConfig } from "@gauloi/common";

export { SUPPORTED_CHAINS };
export type { ChainConfig };

const CHAIN_ENV = process.env.NEXT_PUBLIC_CHAIN_ENV ?? "testnet";

const ENVIRONMENTS = {
  testnet: {
    chains: [SUPPORTED_CHAINS[11155111]!, SUPPORTED_CHAINS[421614]!],
    label: "Testnet" as const,
  },
  mainnet: {
    chains: [SUPPORTED_CHAINS[1]!, SUPPORTED_CHAINS[42161]!],
    label: "Mainnet" as const,
  },
};

export const ENV = ENVIRONMENTS[CHAIN_ENV as keyof typeof ENVIRONMENTS] ?? ENVIRONMENTS.testnet;
export const UI_CHAINS = ENV.chains;
