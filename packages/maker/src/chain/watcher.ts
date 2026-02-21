import {
  type PublicClient,
  type Transport,
  type Chain,
  type Log,
  parseAbiItem,
} from "viem";
import { GauloiEscrowAbi } from "@gauloi/common";

export type FillSubmittedEvent = {
  intentId: `0x${string}`;
  maker: `0x${string}`;
  fillTxHash: `0x${string}`;
  disputeWindowEnd: bigint;
};

export type IntentCreatedEvent = {
  intentId: `0x${string}`;
  taker: `0x${string}`;
  inputToken: `0x${string}`;
  inputAmount: bigint;
  destinationChainId: bigint;
  outputToken: `0x${string}`;
  minOutputAmount: bigint;
};

/**
 * Watches on-chain events on escrow contracts.
 * Used by the dispute watcher to verify fills.
 */
export class ChainWatcher {
  private unwatch: (() => void) | null = null;

  constructor(
    private publicClient: PublicClient<Transport, Chain>,
    private escrowAddress: `0x${string}`,
  ) {}

  /**
   * Watch for FillSubmitted events to verify fills as a dispute watcher.
   */
  watchFills(callback: (event: FillSubmittedEvent) => void): void {
    this.unwatch = this.publicClient.watchContractEvent({
      address: this.escrowAddress,
      abi: GauloiEscrowAbi,
      eventName: "FillSubmitted",
      onLogs: (logs) => {
        for (const log of logs) {
          const args = (log as any).args;
          if (args) {
            callback({
              intentId: args.intentId,
              maker: args.maker,
              fillTxHash: args.fillTxHash,
              disputeWindowEnd: args.disputeWindowEnd,
            });
          }
        }
      },
    });
  }

  stop(): void {
    if (this.unwatch) {
      this.unwatch();
      this.unwatch = null;
    }
  }
}
