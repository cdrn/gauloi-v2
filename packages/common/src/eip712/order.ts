import {
  type WalletClient,
  type Transport,
  type Chain,
  verifyTypedData,
} from "viem";
import { type PrivateKeyAccount } from "viem/accounts";

// EIP-712 types for taker orders — domain includes chainId + verifyingContract
export const ORDER_TYPES = {
  Order: [
    { name: "taker", type: "address" },
    { name: "inputToken", type: "address" },
    { name: "inputAmount", type: "uint256" },
    { name: "outputToken", type: "address" },
    { name: "minOutputAmount", type: "uint256" },
    { name: "destinationChainId", type: "uint256" },
    { name: "destinationAddress", type: "address" },
    { name: "expiry", type: "uint256" },
    { name: "nonce", type: "uint256" },
  ],
} as const;

export interface OrderMessage {
  taker: `0x${string}`;
  inputToken: `0x${string}`;
  inputAmount: bigint;
  outputToken: `0x${string}`;
  minOutputAmount: bigint;
  destinationChainId: bigint;
  destinationAddress: `0x${string}`;
  expiry: bigint;
  nonce: bigint;
}

function orderDomain(escrowAddress: `0x${string}`, chainId: number) {
  return {
    name: "GauloiEscrow",
    version: "1",
    chainId,
    verifyingContract: escrowAddress,
  } as const;
}

/**
 * Sign an order using EIP-712 typed data.
 * Domain includes chainId + verifyingContract to prevent cross-chain replay.
 */
export async function signOrder(
  walletClient: WalletClient<Transport, Chain, PrivateKeyAccount>,
  order: OrderMessage,
  escrowAddress: `0x${string}`,
  chainId: number,
): Promise<`0x${string}`> {
  return walletClient.signTypedData({
    domain: orderDomain(escrowAddress, chainId),
    types: ORDER_TYPES,
    primaryType: "Order",
    message: {
      taker: order.taker,
      inputToken: order.inputToken,
      inputAmount: order.inputAmount,
      outputToken: order.outputToken,
      minOutputAmount: order.minOutputAmount,
      destinationChainId: order.destinationChainId,
      destinationAddress: order.destinationAddress,
      expiry: order.expiry,
      nonce: order.nonce,
    },
  });
}

/**
 * Verify an order signature recovers to the claimed taker address.
 */
export async function verifyOrderSignature(
  order: OrderMessage,
  signature: `0x${string}`,
  escrowAddress: `0x${string}`,
  chainId: number,
): Promise<boolean> {
  try {
    return await verifyTypedData({
      address: order.taker,
      domain: orderDomain(escrowAddress, chainId),
      types: ORDER_TYPES,
      primaryType: "Order",
      message: {
        taker: order.taker,
        inputToken: order.inputToken,
        inputAmount: order.inputAmount,
        outputToken: order.outputToken,
        minOutputAmount: order.minOutputAmount,
        destinationChainId: order.destinationChainId,
        destinationAddress: order.destinationAddress,
        expiry: order.expiry,
        nonce: order.nonce,
      },
      signature,
    });
  } catch {
    return false;
  }
}
