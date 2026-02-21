import {
  type PublicClient,
  type WalletClient,
  type Transport,
  type Chain,
  type Hash,
} from "viem";
import { type PrivateKeyAccount } from "viem/accounts";
import { GauloiEscrowAbi } from "@gauloi/common";

/**
 * Periodically settles matured intents via settleBatch.
 */
export class Settler {
  private interval: ReturnType<typeof setInterval> | null = null;
  private pendingIntents = new Set<`0x${string}`>();

  constructor(
    private publicClient: PublicClient<Transport, Chain>,
    private walletClient: WalletClient<Transport, Chain, PrivateKeyAccount>,
    private escrowAddress: `0x${string}`,
    private settlementWindow: number, // seconds
  ) {}

  /**
   * Track an intent that has been filled and is waiting for settlement.
   */
  trackFill(intentId: `0x${string}`, disputeWindowEnd: number): void {
    this.pendingIntents.add(intentId);
  }

  /**
   * Start the periodic settlement loop.
   */
  start(intervalMs: number = 60_000): void {
    this.interval = setInterval(() => {
      this.trySettle().catch((err) => {
        console.error("Settler error:", err);
      });
    }, intervalMs);
  }

  stop(): void {
    if (this.interval) {
      clearInterval(this.interval);
      this.interval = null;
    }
  }

  async trySettle(): Promise<Hash | null> {
    if (this.pendingIntents.size === 0) return null;

    // Check which intents are past their dispute window
    const matured: `0x${string}`[] = [];

    for (const intentId of this.pendingIntents) {
      try {
        const intent = await this.publicClient.readContract({
          address: this.escrowAddress,
          abi: GauloiEscrowAbi,
          functionName: "getIntent",
          args: [intentId],
        });

        const now = BigInt(Math.floor(Date.now() / 1000));

        // intent[13] is disputeWindowEnd in the struct tuple
        // State must be Filled (2) and past dispute window
        if (intent.state === 2 && intent.disputeWindowEnd <= now) {
          matured.push(intentId);
        }

        // Remove settled/expired intents from tracking
        if (intent.state === 3 || intent.state === 5) {
          this.pendingIntents.delete(intentId);
        }
      } catch {
        // Intent might not exist or RPC error — skip
      }
    }

    if (matured.length === 0) return null;

    console.log(`Settling ${matured.length} matured intent(s)...`);

    const hash = await this.walletClient.writeContract({
      address: this.escrowAddress,
      abi: GauloiEscrowAbi,
      functionName: "settleBatch",
      args: [matured],
    });

    await this.publicClient.waitForTransactionReceipt({ hash });

    // Remove settled intents from tracking
    for (const id of matured) {
      this.pendingIntents.delete(id);
    }

    console.log(`Settled ${matured.length} intent(s): ${hash}`);
    return hash;
  }
}
