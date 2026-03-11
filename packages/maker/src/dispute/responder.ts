import {
  type PublicClient,
  type WalletClient,
  type Transport,
  type Chain,
  type Log,
  decodeFunctionData,
} from "viem";
import { type PrivateKeyAccount } from "viem/accounts";
import {
  GauloiDisputesAbi,
  GauloiEscrowAbi,
  type Order,
  signAttestation,
} from "@gauloi/common";
import { verifyFillOnDestination } from "./verify-fill.js";

interface TrackedDispute {
  intentId: `0x${string}`;
  disputeDeadline: bigint;
  challenger: `0x${string}`;
  maker: `0x${string}`;
}

const ZERO_HASH = "0x0000000000000000000000000000000000000000000000000000000000000000" as `0x${string}`;

/**
 * Responds to DisputeRaised events by verifying fills, signing attestations,
 * and submitting them on-chain. Also finalizes expired disputes.
 */
export class DisputeResponder {
  private unwatch: (() => void) | null = null;
  private interval: ReturnType<typeof setInterval> | null = null;
  private activeDisputes = new Map<string, TrackedDispute>();
  // Sequential queue for DisputeRaised logs to avoid nonce collisions
  private logQueue: Log[] = [];
  private processing = false;

  constructor(
    private sourcePublicClient: PublicClient<Transport, Chain>,
    private sourceWalletClient: WalletClient<Transport, Chain, PrivateKeyAccount>,
    private destPublicClient: PublicClient<Transport, Chain>,
    private disputesAddress: `0x${string}`,
    private escrowAddress: `0x${string}`,
    private makerAddress: `0x${string}`,
    private sourceChainId: number,
  ) {}

  start(pollIntervalMs: number): void {
    // Subscribe to DisputeRaised events
    this.unwatch = this.sourcePublicClient.watchContractEvent({
      address: this.disputesAddress,
      abi: GauloiDisputesAbi,
      eventName: "DisputeRaised",
      onLogs: (logs) => {
        for (const log of logs) {
          this.enqueueLog(log);
        }
      },
    });

    // Start polling for expired dispute finalization
    this.interval = setInterval(() => {
      this.finalizeExpiredDisputes().catch((err) => {
        console.error("Error finalizing expired disputes:", err);
      });
    }, pollIntervalMs);

    console.log("DisputeResponder started");
  }

  stop(): void {
    if (this.unwatch) {
      this.unwatch();
      this.unwatch = null;
    }
    if (this.interval) {
      clearInterval(this.interval);
      this.interval = null;
    }
    console.log("DisputeResponder stopped");
  }

  private enqueueLog(log: Log): void {
    this.logQueue.push(log);
    if (!this.processing) {
      this.processQueue().catch((err) => {
        console.error("Error processing dispute log queue:", err);
      });
    }
  }

  private async processQueue(): Promise<void> {
    this.processing = true;
    try {
      while (this.logQueue.length > 0) {
        const log = this.logQueue.shift()!;
        try {
          await this.handleDisputeRaised(log);
        } catch (err) {
          console.error("Error handling DisputeRaised:", err);
        }
      }
    } finally {
      this.processing = false;
    }
  }

  async handleDisputeRaised(log: Log): Promise<void> {
    const args = (log as any).args;
    if (!args) return;

    const intentId = args.intentId as `0x${string}`;
    const challenger = args.challenger as `0x${string}`;

    console.log(`DisputeRaised detected: ${intentId} by ${challenger}`);

    // Read commitment from escrow
    const commitment = await this.sourcePublicClient.readContract({
      address: this.escrowAddress,
      abi: GauloiEscrowAbi,
      functionName: "getCommitment",
      args: [intentId],
    }) as any;

    const fillTxHash = commitment.fillTxHash as `0x${string}`;
    const maker = commitment.maker as `0x${string}`;

    // Read dispute from disputes contract
    const dispute = await this.sourcePublicClient.readContract({
      address: this.disputesAddress,
      abi: GauloiDisputesAbi,
      functionName: "getDispute",
      args: [intentId],
    }) as any;

    const disputeDeadline = dispute.disputeDeadline as bigint;

    // Track for finalization regardless of eligibility
    this.activeDisputes.set(intentId, {
      intentId,
      disputeDeadline,
      challenger,
      maker,
    });

    // Eligibility check: skip attestation if we're the disputed maker or challenger
    if (this.makerAddress.toLowerCase() === maker.toLowerCase()) {
      console.log(`Skipping attestation for ${intentId}: we are the disputed maker`);
      return;
    }
    if (this.makerAddress.toLowerCase() === challenger.toLowerCase()) {
      console.log(`Skipping attestation for ${intentId}: we are the challenger`);
      return;
    }

    // No fill evidence submitted — attest as invalid
    if (fillTxHash === ZERO_HASH) {
      console.log(`No fill evidence for ${intentId}, attesting as invalid`);
      const signature = await signAttestation(
        this.sourceWalletClient,
        {
          intentId,
          fillValid: false,
          fillTxHash,
          destinationChainId: 0n,
        },
        this.disputesAddress,
        this.sourceChainId,
      );

      try {
        const hash = await this.sourceWalletClient.writeContract({
          address: this.disputesAddress,
          abi: GauloiDisputesAbi,
          functionName: "resolveDispute",
          args: [intentId, false, [signature]],
        });
        console.log(`Attestation (invalid — no fill) submitted for ${intentId}: ${hash}`);
      } catch (err) {
        console.error(`Failed to submit attestation for ${intentId}:`, err);
      }
      return;
    }

    // Decode Order from dispute tx calldata
    const tx = await this.sourcePublicClient.getTransaction({
      hash: log.transactionHash!,
    });

    let order: Order;
    try {
      const decoded = decodeFunctionData({
        abi: GauloiDisputesAbi,
        data: tx.input,
      });
      // dispute(Order order) — first arg is the order tuple
      const raw = (decoded.args as any)[0];
      order = {
        taker: raw.taker,
        inputToken: raw.inputToken,
        inputAmount: raw.inputAmount,
        outputToken: raw.outputToken,
        minOutputAmount: raw.minOutputAmount,
        destinationChainId: raw.destinationChainId,
        destinationAddress: raw.destinationAddress,
        expiry: raw.expiry,
        nonce: raw.nonce,
      };
    } catch (err) {
      console.error(`Failed to decode order from dispute tx for ${intentId}:`, err);
      return;
    }

    // Verify fill on destination chain
    const fillValid = await verifyFillOnDestination(
      this.destPublicClient,
      fillTxHash,
      order,
    );

    console.log(`Fill verification for ${intentId}: ${fillValid ? "valid" : "invalid"}`);

    // Sign attestation
    const signature = await signAttestation(
      this.sourceWalletClient,
      {
        intentId,
        fillValid,
        fillTxHash,
        destinationChainId: order.destinationChainId,
      },
      this.disputesAddress,
      this.sourceChainId,
    );

    // Submit on-chain
    try {
      const hash = await this.sourceWalletClient.writeContract({
        address: this.disputesAddress,
        abi: GauloiDisputesAbi,
        functionName: "resolveDispute",
        args: [intentId, fillValid, [signature]],
      });
      console.log(`Attestation submitted for ${intentId}: ${hash}`);
    } catch (err) {
      console.error(`Failed to submit attestation for ${intentId}:`, err);
    }
  }

  async finalizeExpiredDisputes(): Promise<void> {
    const now = BigInt(Math.floor(Date.now() / 1000));

    for (const [intentId, tracked] of this.activeDisputes) {
      // Skip if deadline hasn't passed
      if (tracked.disputeDeadline > now) continue;

      // Read dispute on-chain to check current state
      const dispute = await this.sourcePublicClient.readContract({
        address: this.disputesAddress,
        abi: GauloiDisputesAbi,
        functionName: "getDispute",
        args: [intentId as `0x${string}`],
      }) as any;

      if (dispute.resolved) {
        this.activeDisputes.delete(intentId);
        continue;
      }

      // Attempt finalization
      try {
        const hash = await this.sourceWalletClient.writeContract({
          address: this.disputesAddress,
          abi: GauloiDisputesAbi,
          functionName: "finalizeExpiredDispute",
          args: [intentId as `0x${string}`],
        });
        console.log(`Finalized expired dispute ${intentId}: ${hash}`);

        // Wait for confirmation before re-reading state
        await this.sourcePublicClient.waitForTransactionReceipt({ hash });
      } catch (err) {
        console.error(`Failed to finalize dispute ${intentId}:`, err);
      }

      // Re-read dispute — may have been extended (quorum failure)
      const updated = await this.sourcePublicClient.readContract({
        address: this.disputesAddress,
        abi: GauloiDisputesAbi,
        functionName: "getDispute",
        args: [intentId as `0x${string}`],
      }) as any;

      if (updated.resolved) {
        this.activeDisputes.delete(intentId);
      } else {
        // Quorum extension — update tracked deadline
        tracked.disputeDeadline = updated.disputeDeadline as bigint;
      }
    }
  }
}
