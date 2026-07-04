import {
  type PublicClient,
  type WalletClient,
  type Transport,
  type Chain,
} from "viem";
import { type PrivateKeyAccount } from "viem/accounts";
import { GauloiDisputesAbi, type Order } from "@gauloi/common";
import type { FillSubmittedEvent } from "../chain/watcher.js";
import { verifyFillOnDestination } from "./verify-fill.js";

/**
 * Monitors fills and challenges invalid ones (v0.2: challenges are
 * permissionless and bond-gated — no maker stake required to challenge).
 * Verifies destination chain fills match intent parameters.
 */
export class DisputeWatcher {
  constructor(
    private destPublicClient: PublicClient<Transport, Chain>,
    private sourceWalletClient: WalletClient<Transport, Chain, PrivateKeyAccount>,
    private disputesAddress: `0x${string}`,
    private makerAddress: `0x${string}`,
  ) {}

  /**
   * Verify a fill by checking the destination chain tx receipt for a matching
   * transfer (correct token, recipient, and amount).
   * Returns true if the fill is valid.
   */
  async verifyFill(event: FillSubmittedEvent, order?: Order): Promise<boolean> {
    // Don't verify our own fills
    if (event.maker.toLowerCase() === this.makerAddress.toLowerCase()) {
      return true;
    }

    if (!order) {
      console.warn(`No order data for intent ${event.intentId} — cannot verify fill`);
      return false;
    }

    return verifyFillOnDestination(this.destPublicClient, event.fillTxHash, order);
  }

  /**
   * Challenge an invalid fill (posts the dispute bond).
   * Requires the original Order data since challenge() takes Order calldata.
   */
  async challenge(intentId: `0x${string}`, order?: Order): Promise<void> {
    if (!order) {
      console.error(`Cannot challenge intent ${intentId}: order data not available`);
      return;
    }

    console.log(`Challenging fill for intent ${intentId}...`);

    try {
      const hash = await this.sourceWalletClient.writeContract({
        address: this.disputesAddress,
        abi: GauloiDisputesAbi,
        functionName: "challenge",
        args: [order],
      });

      console.log(`Challenge submitted: ${hash}`);
    } catch (err) {
      console.error(`Failed to challenge intent ${intentId}:`, err);
    }
  }
}
