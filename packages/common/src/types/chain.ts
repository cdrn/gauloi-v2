export interface ChainConfig {
  chainId: number;
  name: string;
  rpcUrl: string;
  settlementWindow: number; // seconds
  commitmentTimeout: number; // seconds
  escrowAddress: `0x${string}`;
  stakingAddress: `0x${string}`;
  disputesAddress: `0x${string}`;
}
