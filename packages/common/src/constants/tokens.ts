export interface TokenInfo {
  symbol: string;
  decimals: number;
  addresses: Record<number, `0x${string}`>;
}

export const USDC: TokenInfo = {
  symbol: "USDC",
  decimals: 6,
  addresses: {
    1: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", // Ethereum
    42161: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831", // Arbitrum
    11155111: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238", // Sepolia (Circle)
    421614: "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d", // Arbitrum Sepolia (Circle)
  },
};

export const USDT: TokenInfo = {
  symbol: "USDT",
  decimals: 6,
  addresses: {
    1: "0xdAC17F958D2ee523a2206206994597C13D831ec7", // Ethereum
    42161: "0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9", // Arbitrum
  },
};

export const SUPPORTED_TOKENS: Record<string, TokenInfo> = {
  USDC,
  USDT,
};
