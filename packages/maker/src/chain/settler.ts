import {
  type PublicClient,
  type WalletClient,
  type Transport,
  type Chain,
  type Hash,
} from "viem";
import { type PrivateKeyAccount } from "viem/accounts";
import { GauloiEscrowAbi, type Order } from "@gauloi/common";

interface PendingIntent {
  intentId: `0x${string}`;
  order: Order;
}

/**
 * Periodically settles matured intents via settleBatch.
 */
export class Settler {
  private interval: ReturnType<typeof setInterval> | null = null;
  private pendingIntents = new Map<`0x${string}`, PendingIntent>();

  constructor(
    private publicClient: PublicClient<Transport, Chain>,
    private walletClient: WalletClient<Transport, Chain, PrivateKeyAccount>,
    private escrowAddress: `0x${string}`,
    private settlementWindow: number, // seconds
  ) {}

  /**
   * Track an intent that has been filled and is waiting for settlement.
   */
  trackFill(intentId: `0x${string}`, disputeWindowEnd: number, order: Order): void {
    this.pendingIntents.set(intentId, { intentId, order });
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
    const matured: PendingIntent[] = [];

    for (const [intentId, pending] of this.pendingIntents) {
      try {
        const commitment = await this.publicClient.readContract({
          address: this.escrowAddress,
          abi: GauloiEscrowAbi,
          functionName: "getCommitment",
          args: [intentId],
        });

        const now = BigInt(Math.floor(Date.now() / 1000));

        // State must be Filled (1) and past dispute window
        if (commitment.state === 1 && BigInt(commitment.disputeWindowEnd) <= now) {
          matured.push(pending);
        }

        // Remove settled/expired intents from tracking
        // Settled = 2, Expired = 4
        if (commitment.state === 2 || commitment.state === 4) {
          this.pendingIntents.delete(intentId);
        }
      } catch {
        // Intent might not exist or RPC error — skip
      }
    }

    if (matured.length === 0) return null;

    console.log(`Settling ${matured.length} matured intent(s)...`);

    const orders = matured.map((p) => p.order);

    const hash = await this.walletClient.writeContract({
      address: this.escrowAddress,
      abi: GauloiEscrowAbi,
      functionName: "settleBatch",
      args: [orders],
    });

    await this.publicClient.waitForTransactionReceipt({ hash });

    // Remove settled intents from tracking
    for (const p of matured) {
      this.pendingIntents.delete(p.intentId);
    }

    console.log(`Settled ${matured.length} intent(s): ${hash}`);
    return hash;
  }
}
