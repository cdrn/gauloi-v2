export interface ChainConfig {
  chainId: number;
  name: string;
  rpcUrl: string;
  settlementWindow: number; // seconds (default; corridors may override on-chain)
  commitmentTimeout: number; // seconds
  escrowAddress: `0x${string}`;
  stakingAddress: `0x${string}`;
  disputesAddress: `0x${string}`;
  // v0.2: destination-side fill registry (fills route through it, keyed by intentId)
  fillRegistryAddress: `0x${string}`;
  // v0.2: council resolver adjudicating disputes for corridors served from this chain
  councilAddress: `0x${string}`;
}
