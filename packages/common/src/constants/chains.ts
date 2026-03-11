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
  escrowAddress: "0xa32D78ac618B41f5E7Ace535b921f1b06D87118E",
  stakingAddress: "0x140901e3285c01A051b1E904e4f90e2345bC0F3a",
  disputesAddress: "0xb4d5A4ea7D0Ec9A57a07d24f1A51a3Ca7ade526F",
};

export const ARBITRUM_SEPOLIA: ChainConfig = {
  chainId: 421614,
  name: "Arbitrum Sepolia",
  rpcUrl: process.env.ARBITRUM_SEPOLIA_RPC_URL ?? "",
  settlementWindow: 2 * 60, // 2 minutes (testnet)
  commitmentTimeout: 2 * 60, // 2 minutes
  escrowAddress: "0x0AE9C298A70f10A217D7b017A7aBF64c9bB52579",
  stakingAddress: "0x845E14C0473356064b6fA7371635F5FAE8AE62B3",
  disputesAddress: "0x877042524F713fa191687A70D6142cbF1C3cfec6",
};

export const SUPPORTED_CHAINS: Record<number, ChainConfig> = {
  [ETHEREUM_MAINNET.chainId]: ETHEREUM_MAINNET,
  [ARBITRUM.chainId]: ARBITRUM,
  [SEPOLIA.chainId]: SEPOLIA,
  [ARBITRUM_SEPOLIA.chainId]: ARBITRUM_SEPOLIA,
};
