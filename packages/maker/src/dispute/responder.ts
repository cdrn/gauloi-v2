import {
  type PublicClient,
  type WalletClient,
  type Transport,
  type Chain,
  decodeFunctionData,
} from "viem";
import { type PrivateKeyAccount } from "viem/accounts";
import {
  GauloiDisputesAbi,
  GauloiEscrowAbi,
  type Order,
  signAttestation,
  ZERO_BYTES32,
} from "@gauloi/common";
import { verifyFillOnDestination } from "./verify-fill.js";

/** Decoded DisputeRaised event log as returned by watchContractEvent */
export interface DisputeRaisedLog {
  args: {
    intentId: `0x${string}`;
    challenger: `0x${string}`;
    bondAmount: bigint;
  };
  transactionHash: `0x${string}`;
}

interface TrackedDispute {
  intentId: `0x${string}`;
  disputeDeadline: bigint;
  challenger: `0x${string}`;
  maker: `0x${string}`;
}

interface PendingAttestation {
  intentId: `0x${string}`;
  fillValid: boolean;
  signature: `0x${string}`;
  retries: number;
}

const MAX_ATTESTATION_RETRIES = 5;


/**
 * Responds to DisputeRaised events by verifying fills, signing attestations,
 * and submitting them on-chain. Also finalizes expired disputes.
 */
export class DisputeResponder {
  private unwatch: (() => void) | null = null;
  private interval: ReturnType<typeof setInterval> | null = null;
  private activeDisputes = new Map<string, TrackedDispute>();
  private pendingAttestations = new Map<string, PendingAttestation>();
  // Sequential work queue — all writeContract calls go through here to avoid nonce collisions
  private workQueue: (() => Promise<void>)[] = [];
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
          const args = log.args;
          if (!args.intentId || !args.challenger) continue;
          if (!log.transactionHash) {
            console.warn(`Skipping DisputeRaised log with no transactionHash for ${args.intentId}`);
            continue;
          }
          this.enqueueWork(() => this.handleDisputeRaised({
            args: args as DisputeRaisedLog["args"],
            transactionHash: log.transactionHash,
          }));
        }
      },
    });

    // Start polling for expired dispute finalization and attestation retries
    this.interval = setInterval(() => {
      this.enqueueWork(() => this.retryPendingAttestations());
      this.enqueueWork(() => this.finalizeExpiredDisputes());
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

  private enqueueWork(fn: () => Promise<void>): void {
    this.workQueue.push(fn);
    if (!this.processing) {
      this.processQueue().catch((err) => {
        console.error("Error processing dispute work queue:", err);
      });
    }
  }

  private async processQueue(): Promise<void> {
    this.processing = true;
    try {
      while (this.workQueue.length > 0) {
        const work = this.workQueue.shift()!;
        try {
          await work();
        } catch (err) {
          console.error("Error in dispute work queue:", err);
        }
      }
    } finally {
      this.processing = false;
      // Re-check: items may have been enqueued after the while loop drained
      if (this.workQueue.length > 0) {
        this.processQueue().catch((err) => {
          console.error("Error processing dispute work queue:", err);
        });
      }
    }
  }

  async handleDisputeRaised(log: DisputeRaisedLog): Promise<void> {
    const { intentId, challenger } = log.args;

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

    // Decode Order from dispute tx calldata — needed for both attestation paths
    // because resolveDispute recovers signatures using order.destinationChainId
    let order: Order;
    try {
      const tx = await this.sourcePublicClient.getTransaction({
        hash: log.transactionHash!,
      });

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

    // No fill evidence submitted — attest as invalid
    if (fillTxHash === ZERO_BYTES32) {
      console.log(`No fill evidence for ${intentId}, attesting as invalid`);
      const signature = await signAttestation(
        this.sourceWalletClient,
        {
          intentId,
          fillValid: false,
          fillTxHash,
          destinationChainId: order.destinationChainId,
        },
        this.disputesAddress,
        this.sourceChainId,
      );

      await this.submitAttestation(intentId, false, signature);
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

    // Submit on-chain (queues for retry on failure)
    await this.submitAttestation(intentId, fillValid, signature);
  }

  private async submitAttestation(
    intentId: `0x${string}`,
    fillValid: boolean,
    signature: `0x${string}`,
  ): Promise<void> {
    try {
      const hash = await this.sourceWalletClient.writeContract({
        address: this.disputesAddress,
        abi: GauloiDisputesAbi,
        functionName: "resolveDispute",
        args: [intentId, fillValid, [signature]],
      });
      console.log(`Attestation submitted for ${intentId}: ${hash}`);
      this.pendingAttestations.delete(intentId);
    } catch (err) {
      const pending = this.pendingAttestations.get(intentId);
      const retries = pending ? pending.retries + 1 : 1;
      if (retries > MAX_ATTESTATION_RETRIES) {
        console.error(`Attestation for ${intentId} failed after ${MAX_ATTESTATION_RETRIES} retries, giving up`);
        this.pendingAttestations.delete(intentId);
      } else {
        console.error(`Failed to submit attestation for ${intentId} (attempt ${retries}/${MAX_ATTESTATION_RETRIES}):`, err);
        this.pendingAttestations.set(intentId, { intentId, fillValid, signature, retries });
      }
    }
  }

  async retryPendingAttestations(): Promise<void> {
    // Snapshot keys to avoid mutating the map during iteration
    const pendingEntries = [...this.pendingAttestations.entries()];

    for (const [intentId, pending] of pendingEntries) {
      // Check if dispute is already resolved before retrying
      const dispute = await this.sourcePublicClient.readContract({
        address: this.disputesAddress,
        abi: GauloiDisputesAbi,
        functionName: "getDispute",
        args: [intentId as `0x${string}`],
      }) as any;

      if (dispute.resolved) {
        console.log(`Dispute ${intentId} already resolved, dropping pending attestation`);
        this.pendingAttestations.delete(intentId);
        continue;
      }

      await this.submitAttestation(pending.intentId, pending.fillValid, pending.signature);
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
        continue;
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
