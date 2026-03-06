import {
  type PublicClient,
  type WalletClient,
  type Transport,
  type Chain,
  parseAbiItem,
  decodeEventLog,
} from "viem";
import { type PrivateKeyAccount } from "viem/accounts";
import { GauloiDisputesAbi, type Order } from "@gauloi/common";
import type { FillSubmittedEvent } from "../chain/watcher.js";

const ERC20_TRANSFER_EVENT = parseAbiItem(
  "event Transfer(address indexed from, address indexed to, uint256 value)",
);

/**
 * Monitors fills and disputes invalid ones.
 * Verifies destination chain ERC20 Transfer logs match intent parameters.
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
   * ERC20 Transfer log (correct token, recipient, and amount).
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

    try {
      const receipt = await this.destPublicClient.getTransactionReceipt({
        hash: event.fillTxHash,
      });

      if (receipt.status === "reverted") {
        return false;
      }

      // Look for an ERC20 Transfer log on the output token contract
      // that sends at least minOutputAmount to the destination address
      for (const log of receipt.logs) {
        // Skip logs from other contracts
        if (log.address.toLowerCase() !== order.outputToken.toLowerCase()) {
          continue;
        }

        try {
          const decoded = decodeEventLog({
            abi: [ERC20_TRANSFER_EVENT],
            data: log.data,
            topics: log.topics,
          });

          if (decoded.eventName !== "Transfer") continue;

          const { to, value } = decoded.args;

          const recipientMatch =
            to.toLowerCase() === order.destinationAddress.toLowerCase();
          const amountSufficient = value >= order.minOutputAmount;

          if (recipientMatch && amountSufficient) {
            return true;
          }
        } catch {
          // Not a Transfer event or wrong ABI — skip
        }
      }

      // No matching Transfer log found
      return false;
    } catch {
      // Transaction not found — potentially fraudulent
      return false;
    }
  }

  /**
   * Raise a dispute for an invalid fill.
   * Requires the original Order data since dispute() now takes Order calldata.
   */
  async dispute(intentId: `0x${string}`, order?: Order): Promise<void> {
    if (!order) {
      console.error(`Cannot dispute intent ${intentId}: order data not available`);
      return;
    }

    console.log(`Disputing fill for intent ${intentId}...`);

    try {
      const hash = await this.sourceWalletClient.writeContract({
        address: this.disputesAddress,
        abi: GauloiDisputesAbi,
        functionName: "dispute",
        args: [order],
      });

      console.log(`Dispute submitted: ${hash}`);
    } catch (err) {
      console.error(`Failed to dispute intent ${intentId}:`, err);
    }
  }
}
