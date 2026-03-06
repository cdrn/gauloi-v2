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
  escrowAddress: "0x4A01bc51DF2c58C9fCad0413B3417a47bADE0e52",
  stakingAddress: "0x363531686E6a0B1A52189bE878038075B14cBCcB",
  disputesAddress: "0x49CFF580Ad8A15B82a22f9376e65Dc9CebFEc94a",
};

export const ARBITRUM_SEPOLIA: ChainConfig = {
  chainId: 421614,
  name: "Arbitrum Sepolia",
  rpcUrl: process.env.ARBITRUM_SEPOLIA_RPC_URL ?? "",
  settlementWindow: 2 * 60, // 2 minutes (testnet)
  commitmentTimeout: 2 * 60, // 2 minutes
  escrowAddress: "0xf9fFa89F4B3d3b63c389D91B06D805534BcE9256",
  stakingAddress: "0x61bc65601290bD7CBfF2461a1C2B81d0892064Dd",
  disputesAddress: "0x9938386603295918D6A4167839297fCB46FaF3E1",
};

export const SUPPORTED_CHAINS: Record<number, ChainConfig> = {
  [ETHEREUM_MAINNET.chainId]: ETHEREUM_MAINNET,
  [ARBITRUM.chainId]: ARBITRUM,
  [SEPOLIA.chainId]: SEPOLIA,
  [ARBITRUM_SEPOLIA.chainId]: ARBITRUM_SEPOLIA,
};
