import {
  type WalletClient,
  type Transport,
  type Chain,
  verifyTypedData,
} from "viem";
import { type PrivateKeyAccount } from "viem/accounts";

// EIP-712 domain — no chainId since quotes are cross-chain
export const QUOTE_DOMAIN = {
  name: "Gauloi",
  version: "1",
} as const;

// EIP-712 types for maker quotes
export const QUOTE_TYPES = {
  Quote: [
    { name: "intentId", type: "bytes32" },
    { name: "maker", type: "address" },
    { name: "outputAmount", type: "uint256" },
    { name: "estimatedFillTime", type: "uint256" },
    { name: "expiry", type: "uint256" },
  ],
} as const;

export interface QuoteMessage {
  intentId: `0x${string}`;
  maker: `0x${string}`;
  outputAmount: bigint;
  estimatedFillTime: number;
  expiry: number;
}

/**
 * Sign a quote using EIP-712 typed data.
 */
export async function signQuote(
  walletClient: WalletClient<Transport, Chain, PrivateKeyAccount>,
  quote: QuoteMessage,
): Promise<`0x${string}`> {
  return walletClient.signTypedData({
    domain: QUOTE_DOMAIN,
    types: QUOTE_TYPES,
    primaryType: "Quote",
    message: {
      intentId: quote.intentId,
      maker: quote.maker,
      outputAmount: quote.outputAmount,
      estimatedFillTime: BigInt(quote.estimatedFillTime),
      expiry: BigInt(quote.expiry),
    },
  });
}

/**
 * Verify a quote signature recovers to the claimed maker address.
 */
export async function verifyQuoteSignature(
  quote: QuoteMessage,
  signature: `0x${string}`,
): Promise<boolean> {
  try {
    return await verifyTypedData({
      address: quote.maker,
      domain: QUOTE_DOMAIN,
      types: QUOTE_TYPES,
      primaryType: "Quote",
      message: {
        intentId: quote.intentId,
        maker: quote.maker,
        outputAmount: quote.outputAmount,
        estimatedFillTime: BigInt(quote.estimatedFillTime),
        expiry: BigInt(quote.expiry),
      },
      signature,
    });
  } catch {
    return false;
  }
}
