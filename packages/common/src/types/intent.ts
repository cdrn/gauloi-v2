export enum IntentState {
  Open = 0,
  Committed = 1,
  Filled = 2,
  Settled = 3,
  Disputed = 4,
  Expired = 5,
}

export interface Intent {
  intentId: `0x${string}`;
  taker: `0x${string}`;
  inputToken: `0x${string}`;
  inputAmount: bigint;
  destinationChainId: bigint;
  destinationAddress: `0x${string}`;
  outputToken: `0x${string}`;
  minOutputAmount: bigint;
  expiry: bigint;
  state: IntentState;
  maker: `0x${string}`;
  commitmentDeadline: bigint;
  fillTxHash: `0x${string}`;
  disputeWindowEnd: bigint;
}
