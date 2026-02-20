export interface MakerQuote {
  intentId: `0x${string}`;
  maker: `0x${string}`;
  outputAmount: bigint;
  estimatedFillTime: number; // seconds
  expiry: number; // unix timestamp
  signature: `0x${string}`;
}
