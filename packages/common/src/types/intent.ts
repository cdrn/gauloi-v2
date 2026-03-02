export enum IntentState {
  Committed = 0,
  Filled = 1,
  Settled = 2,
  Disputed = 3,
  Expired = 4,
}

export interface Order {
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

export interface Commitment {
  taker: `0x${string}`;
  state: IntentState;
  maker: `0x${string}`;
  commitmentDeadline: number;
  disputeWindowEnd: number;
  fillTxHash: `0x${string}`;
}
