const SIZE = 16;

interface IconProps {
  size?: number;
  className?: string;
}

export function EthereumIcon({ size = SIZE, className }: IconProps) {
  return (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none" className={className}>
      <path d="M16 2L6 16.5L16 22L26 16.5L16 2Z" fill="#627EEA" />
      <path d="M16 2L6 16.5L16 22V2Z" fill="#627EEA" opacity="0.6" />
      <path d="M16 24L6 18.5L16 30L26 18.5L16 24Z" fill="#627EEA" />
      <path d="M16 24L6 18.5L16 30V24Z" fill="#627EEA" opacity="0.6" />
    </svg>
  );
}

export function ArbitrumIcon({ size = SIZE, className }: IconProps) {
  return (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none" className={className}>
      <rect width="32" height="32" rx="6" fill="#213147" />
      <path d="M16.2 7L8 21.5H12L16.2 14L20.4 21.5H24.4L16.2 7Z" fill="#12AAFF" />
      <path d="M12 21.5L14 25H18.4L16.2 21.5L14.4 18L12 21.5Z" fill="white" />
      <path d="M20.4 21.5L18.4 25H22L24.4 21.5H20.4Z" fill="white" />
    </svg>
  );
}

export function UsdcIcon({ size = SIZE, className }: IconProps) {
  return (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none" className={className}>
      <circle cx="16" cy="16" r="15" fill="#2775CA" />
      <path
        d="M20.5 18.5C20.5 16.3 19.2 15.5 16.5 15.2C14.5 14.9 14.1 14.4 14.1 13.5C14.1 12.6 14.7 12 16 12C17.1 12 17.7 12.4 18 13.3C18.1 13.5 18.2 13.6 18.4 13.6H19.6C19.8 13.6 20 13.4 20 13.2V13.1C19.7 11.8 18.7 10.8 17.3 10.6V9.3C17.3 9.1 17.1 8.9 16.8 8.9H15.6C15.4 8.9 15.2 9.1 15.1 9.3V10.5C13.3 10.8 12.2 12 12.2 13.6C12.2 15.7 13.5 16.5 16.2 16.8C18 17.2 18.6 17.6 18.6 18.6C18.6 19.6 17.7 20.2 16.5 20.2C14.9 20.2 14.3 19.5 14.1 18.6C14 18.4 13.9 18.3 13.7 18.3H12.4C12.2 18.3 12 18.5 12 18.7V18.8C12.3 20.3 13.4 21.3 15.2 21.6V22.8C15.2 23 15.4 23.2 15.7 23.2H16.9C17.1 23.2 17.3 23 17.4 22.8V21.6C19.2 21.2 20.5 20 20.5 18.5Z"
        fill="white"
      />
    </svg>
  );
}

export function UsdtIcon({ size = SIZE, className }: IconProps) {
  return (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none" className={className}>
      <circle cx="16" cy="16" r="15" fill="#26A17B" />
      <path
        d="M17.9 17.1V17.1C17.8 17.1 17 17.2 16 17.2C15.2 17.2 14.3 17.1 14.1 17.1C10.8 16.9 8.4 16.2 8.4 15.3C8.4 14.4 10.8 13.7 14.1 13.5V16.4C14.3 16.4 15.2 16.5 16.1 16.5C17.1 16.5 17.8 16.4 17.9 16.4V13.5C21.2 13.7 23.5 14.4 23.5 15.3C23.5 16.2 21.2 16.9 17.9 17.1ZM17.9 13.3V10.7H22.5V7.5H9.5V10.7H14.1V13.3C10.3 13.5 7.5 14.5 7.5 15.6C7.5 16.8 10.3 17.7 14.1 17.9V25H17.9V17.9C21.7 17.7 24.5 16.8 24.5 15.6C24.5 14.5 21.7 13.5 17.9 13.3Z"
        fill="white"
      />
    </svg>
  );
}

// Maps chain IDs to their icon components
export function ChainIcon({ chainId, size, className }: { chainId: number; size?: number; className?: string }) {
  switch (chainId) {
    case 1:
    case 11155111:
      return <EthereumIcon size={size} className={className} />;
    case 42161:
    case 421614:
      return <ArbitrumIcon size={size} className={className} />;
    default:
      return null;
  }
}

export function TokenIcon({ symbol, size, className }: { symbol: string; size?: number; className?: string }) {
  switch (symbol) {
    case "USDC":
      return <UsdcIcon size={size} className={className} />;
    case "USDT":
      return <UsdtIcon size={size} className={className} />;
    default:
      return null;
  }
}
