import {
  type PublicClient,
  type WalletClient,
  type Transport,
  type Chain,
  type Hash,
  getContract,
} from "viem";
import { type PrivateKeyAccount } from "viem/accounts";
import { GauloiEscrowAbi } from "@gauloi/common";

/**
 * Handles on-chain operations for the maker:
 * - commitToIntent on source chain
 * - transfer tokens on destination chain (the actual fill)
 * - submitFill on source chain
 */
export class Filler {
  constructor(
    private sourcePublic: PublicClient<Transport, Chain>,
    private sourceWallet: WalletClient<Transport, Chain, PrivateKeyAccount>,
    private destPublic: PublicClient<Transport, Chain>,
    private destWallet: WalletClient<Transport, Chain, PrivateKeyAccount>,
    private escrowAddress: `0x${string}`,
  ) {}

  async commitToIntent(intentId: `0x${string}`): Promise<Hash> {
    const hash = await this.sourceWallet.writeContract({
      address: this.escrowAddress,
      abi: GauloiEscrowAbi,
      functionName: "commitToIntent",
      args: [intentId],
    });

    await this.sourcePublic.waitForTransactionReceipt({ hash });
    return hash;
  }

  /**
   * Execute the fill on the destination chain.
   * For v0.1 this is a simple ERC20 transfer.
   */
  async fillOnDestination(
    outputToken: `0x${string}`,
    destinationAddress: `0x${string}`,
    outputAmount: bigint,
  ): Promise<Hash> {
    // Standard ERC20 transfer
    const hash = await this.destWallet.writeContract({
      address: outputToken,
      abi: [
        {
          type: "function",
          name: "transfer",
          inputs: [
            { name: "to", type: "address" },
            { name: "amount", type: "uint256" },
          ],
          outputs: [{ type: "bool" }],
          stateMutability: "nonpayable",
        },
      ] as const,
      functionName: "transfer",
      args: [destinationAddress, outputAmount],
    });

    const receipt = await this.destPublic.waitForTransactionReceipt({ hash });
    return receipt.transactionHash;
  }

  async submitFill(
    intentId: `0x${string}`,
    destinationTxHash: `0x${string}`,
  ): Promise<Hash> {
    const hash = await this.sourceWallet.writeContract({
      address: this.escrowAddress,
      abi: GauloiEscrowAbi,
      functionName: "submitFill",
      args: [intentId, destinationTxHash],
    });

    await this.sourcePublic.waitForTransactionReceipt({ hash });
    return hash;
  }
}
