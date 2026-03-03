import {
  createPublicClient,
  createWalletClient,
  http,
  type PublicClient,
  type WalletClient,
  type Transport,
  type Chain,
} from "viem";
import { mainnet, arbitrum, sepolia, arbitrumSepolia } from "viem/chains";
import { privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";
import type { ChainConfig } from "./types/chain";

const viemChains: Record<number, Chain> = {
  1: mainnet,
  42161: arbitrum,
  11155111: sepolia,
  421614: arbitrumSepolia,
};

export function getPublicClient(config: ChainConfig): PublicClient<Transport, Chain> {
  const chain = viemChains[config.chainId];
  if (!chain) throw new Error(`Unsupported chain: ${config.chainId}`);

  return createPublicClient({
    chain,
    transport: http(config.rpcUrl || undefined),
  });
}

export function getWalletClient(
  config: ChainConfig,
  privateKey: `0x${string}`,
): WalletClient<Transport, Chain, PrivateKeyAccount> {
  const chain = viemChains[config.chainId];
  if (!chain) throw new Error(`Unsupported chain: ${config.chainId}`);

  return createWalletClient({
    account: privateKeyToAccount(privateKey),
    chain,
    transport: http(config.rpcUrl || undefined),
  });
}
