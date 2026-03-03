import type { ChainConfig } from "../types/chain";

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
  escrowAddress: "0x61bc65601290bD7CBfF2461a1C2B81d0892064Dd",
  stakingAddress: "0xc157d212a20361f8DBD4D6D890Ba19C62E1bf181",
  disputesAddress: "0xf9fFa89F4B3d3b63c389D91B06D805534BcE9256",
};

export const ARBITRUM_SEPOLIA: ChainConfig = {
  chainId: 421614,
  name: "Arbitrum Sepolia",
  rpcUrl: process.env.ARBITRUM_SEPOLIA_RPC_URL ?? "",
  settlementWindow: 2 * 60, // 2 minutes (testnet)
  commitmentTimeout: 2 * 60, // 2 minutes
  escrowAddress: "0x94AC29e9888314Bf9Addc60c7CB3FFa876e7565a",
  stakingAddress: "0x34C49c7fe668cDdD13a8Af5677d3d71d57eFdddc",
  disputesAddress: "0xe2D845c033F8BEF0d10c6c1B06BdE4882f3b0f8a",
};

export const SUPPORTED_CHAINS: Record<number, ChainConfig> = {
  [ETHEREUM_MAINNET.chainId]: ETHEREUM_MAINNET,
  [ARBITRUM.chainId]: ARBITRUM,
  [SEPOLIA.chainId]: SEPOLIA,
  [ARBITRUM_SEPOLIA.chainId]: ARBITRUM_SEPOLIA,
};
