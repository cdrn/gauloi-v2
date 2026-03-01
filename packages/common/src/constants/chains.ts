import type { ChainConfig } from "../types/chain.js";

// Placeholder addresses — filled after deployment
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000" as const;

export const ETHEREUM_MAINNET: ChainConfig = {
  chainId: 1,
  name: "Ethereum",
  rpcUrl: process.env.ETHEREUM_RPC_URL ?? "",
  settlementWindow: 15 * 60, // 15 minutes
  commitmentTimeout: 5 * 60, // 5 minutes
  escrowAddress: ZERO_ADDRESS,
  stakingAddress: ZERO_ADDRESS,
  disputesAddress: ZERO_ADDRESS,
};

export const ARBITRUM: ChainConfig = {
  chainId: 42161,
  name: "Arbitrum",
  rpcUrl: process.env.ARBITRUM_RPC_URL ?? "",
  settlementWindow: 30 * 60, // 30 minutes
  commitmentTimeout: 5 * 60, // 5 minutes
  escrowAddress: ZERO_ADDRESS,
  stakingAddress: ZERO_ADDRESS,
  disputesAddress: ZERO_ADDRESS,
};

export const SEPOLIA: ChainConfig = {
  chainId: 11155111,
  name: "Sepolia",
  rpcUrl: process.env.SEPOLIA_RPC_URL ?? "",
  settlementWindow: 2 * 60, // 2 minutes (testnet)
  commitmentTimeout: 2 * 60, // 2 minutes
  escrowAddress: ZERO_ADDRESS,
  stakingAddress: ZERO_ADDRESS,
  disputesAddress: ZERO_ADDRESS,
};

export const ARBITRUM_SEPOLIA: ChainConfig = {
  chainId: 421614,
  name: "Arbitrum Sepolia",
  rpcUrl: process.env.ARBITRUM_SEPOLIA_RPC_URL ?? "",
  settlementWindow: 2 * 60, // 2 minutes (testnet)
  commitmentTimeout: 2 * 60, // 2 minutes
  escrowAddress: ZERO_ADDRESS,
  stakingAddress: ZERO_ADDRESS,
  disputesAddress: ZERO_ADDRESS,
};

export const SUPPORTED_CHAINS: Record<number, ChainConfig> = {
  [ETHEREUM_MAINNET.chainId]: ETHEREUM_MAINNET,
  [ARBITRUM.chainId]: ARBITRUM,
  [SEPOLIA.chainId]: SEPOLIA,
  [ARBITRUM_SEPOLIA.chainId]: ARBITRUM_SEPOLIA,
};
