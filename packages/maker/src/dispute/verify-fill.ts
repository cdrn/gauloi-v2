import {
  type PublicClient,
  type Transport,
  type Chain,
  parseAbiItem,
  decodeEventLog,
} from "viem";
import type { Order } from "@gauloi/common";

export const ERC20_TRANSFER_EVENT = parseAbiItem(
  "event Transfer(address indexed from, address indexed to, uint256 value)",
);

/**
 * Verify a fill by checking the destination chain tx receipt for a matching
 * ERC20 Transfer log (correct token, recipient, and amount).
 * Returns true if the fill is valid.
 */
export async function verifyFillOnDestination(
  destPublicClient: PublicClient<Transport, Chain>,
  fillTxHash: `0x${string}`,
  order: Order,
): Promise<boolean> {
  try {
    const receipt = await destPublicClient.getTransactionReceipt({
      hash: fillTxHash,
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
