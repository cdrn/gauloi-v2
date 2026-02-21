import {
  type PublicClient,
  type WalletClient,
  type Transport,
  type Chain,
} from "viem";
import { type PrivateKeyAccount } from "viem/accounts";
import { GauloiDisputesAbi } from "@gauloi/common";
import type { FillSubmittedEvent } from "../chain/watcher.js";

/**
 * Monitors fills and disputes invalid ones.
 * For v0.1, verification is simulated — in production this
 * would check the destination chain RPC for the claimed tx.
 */
export class DisputeWatcher {
  constructor(
    private destPublicClient: PublicClient<Transport, Chain>,
    private sourceWalletClient: WalletClient<Transport, Chain, PrivateKeyAccount>,
    private disputesAddress: `0x${string}`,
    private makerAddress: `0x${string}`,
  ) {}

  /**
   * Verify a fill by checking the destination chain for the claimed transaction.
   * Returns true if the fill is valid.
   */
  async verifyFill(event: FillSubmittedEvent): Promise<boolean> {
    // Don't verify our own fills
    if (event.maker.toLowerCase() === this.makerAddress.toLowerCase()) {
      return true;
    }

    try {
      // Check if the transaction exists on the destination chain
      const tx = await this.destPublicClient.getTransaction({
        hash: event.fillTxHash,
      });

      // Transaction exists — basic validity check
      // In production: verify recipient, amount, token match the intent parameters
      return tx !== null;
    } catch {
      // Transaction not found — potentially fraudulent
      return false;
    }
  }

  /**
   * Raise a dispute for an invalid fill.
   */
  async dispute(intentId: `0x${string}`): Promise<void> {
    console.log(`Disputing fill for intent ${intentId}...`);

    try {
      const hash = await this.sourceWalletClient.writeContract({
        address: this.disputesAddress,
        abi: GauloiDisputesAbi,
        functionName: "dispute",
        args: [intentId],
      });

      console.log(`Dispute submitted: ${hash}`);
    } catch (err) {
      console.error(`Failed to dispute intent ${intentId}:`, err);
    }
  }
}
