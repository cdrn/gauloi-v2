import {
  type PublicClient,
  type WalletClient,
  type Transport,
  type Chain,
  type Hash,
  erc20Abi,
  maxUint256,
} from "viem";
import { type PrivateKeyAccount } from "viem/accounts";
import { GauloiEscrowAbi, GauloiFillRegistryAbi, type Order } from "@gauloi/common";

/**
 * Handles on-chain operations for the maker:
 * - executeOrder on source chain (pulls tokens from taker, commits)
 * - fill through the destination FillRegistry (records the fill as a canonical
 *   on-chain fact keyed by intentId — one fill per intent, one intent per fill)
 * - submitFill on source chain
 */
export class Filler {
  constructor(
    private sourcePublic: PublicClient<Transport, Chain>,
    private sourceWallet: WalletClient<Transport, Chain, PrivateKeyAccount>,
    private destPublic: PublicClient<Transport, Chain>,
    private destWallet: WalletClient<Transport, Chain, PrivateKeyAccount>,
    private escrowAddress: `0x${string}`,
    private destFillRegistryAddress: `0x${string}`,
  ) {}

  async executeOrder(order: Order, takerSignature: `0x${string}`): Promise<Hash> {
    const hash = await this.sourceWallet.writeContract({
      address: this.escrowAddress,
      abi: GauloiEscrowAbi,
      functionName: "executeOrder",
      args: [order, takerSignature],
    });

    await this.sourcePublic.waitForTransactionReceipt({ hash });
    return hash;
  }

  /**
   * Execute the fill on the destination chain through the FillRegistry.
   * The registry transfers the tokens and records the fill against the intentId.
   */
  async fillOnDestination(
    intentId: `0x${string}`,
    outputToken: `0x${string}`,
    destinationAddress: `0x${string}`,
    outputAmount: bigint,
  ): Promise<Hash> {
    await this.ensureRegistryAllowance(outputToken, outputAmount);

    const hash = await this.destWallet.writeContract({
      address: this.destFillRegistryAddress,
      abi: GauloiFillRegistryAbi,
      functionName: "fill",
      args: [intentId, outputToken, destinationAddress, outputAmount],
    });

    const receipt = await this.destPublic.waitForTransactionReceipt({ hash });
    return receipt.transactionHash;
  }

  async submitFill(order: Order, destinationTxHash: `0x${string}`): Promise<Hash> {
    const hash = await this.sourceWallet.writeContract({
      address: this.escrowAddress,
      abi: GauloiEscrowAbi,
      functionName: "submitFill",
      args: [order, destinationTxHash],
    });

    await this.sourcePublic.waitForTransactionReceipt({ hash });
    return hash;
  }

  /** Approve the registry once (max) per output token, only when needed */
  private async ensureRegistryAllowance(token: `0x${string}`, amount: bigint): Promise<void> {
    const allowance = await this.destPublic.readContract({
      address: token,
      abi: erc20Abi,
      functionName: "allowance",
      args: [this.destWallet.account.address, this.destFillRegistryAddress],
    });

    if (allowance >= amount) return;

    const hash = await this.destWallet.writeContract({
      address: token,
      abi: erc20Abi,
      functionName: "approve",
      args: [this.destFillRegistryAddress, maxUint256],
    });
    await this.destPublic.waitForTransactionReceipt({ hash });
  }
}
