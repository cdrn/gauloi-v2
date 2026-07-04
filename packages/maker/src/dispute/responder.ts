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
  CouncilResolverAbi,
  type Order,
  signCouncilVerdict,
  encodeCouncilEvidence,
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

interface PendingResolution {
  intentId: `0x${string}`;
  evidence: `0x${string}`;
  retries: number;
}

const MAX_RESOLUTION_RETRIES = 5;

/**
 * Responds to DisputeRaised events under the v0.2 trust model:
 *
 * - A challenged fill unresolved by the deadline resolves INVALID (the maker
 *   must defend; silence convicts). So when OUR fill is challenged, defending
 *   is mandatory, not optional.
 * - Judgment terminates in the corridor's resolver. On council corridors, if
 *   this bot's account is a council member with a reachable threshold of 1,
 *   it verifies the fill honestly and submits the verdict itself (bootstrap
 *   mode). Otherwise it escalates loudly for out-of-band council action.
 * - Disputes we challenged are finalized after the deadline — finalization
 *   resolves in the challenger's favor and pays the challenger reward.
 *
 * There is no attestation vote in v0.2; that machinery is gone.
 */
export class DisputeResponder {
  private unwatch: (() => void) | null = null;
  private interval: ReturnType<typeof setInterval> | null = null;
  private activeDisputes = new Map<string, TrackedDispute>();
  private pendingResolutions = new Map<string, PendingResolution>();
  // Sequential work queue — all writeContract calls go through here to avoid nonce collisions
  private workQueue: (() => Promise<void>)[] = [];
  private processing = false;
  // Whether this bot can act as a 1-of-N council (checked once at start)
  private canSoloResolve = false;

  constructor(
    private sourcePublicClient: PublicClient<Transport, Chain>,
    private sourceWalletClient: WalletClient<Transport, Chain, PrivateKeyAccount>,
    private destPublicClient: PublicClient<Transport, Chain>,
    private disputesAddress: `0x${string}`,
    private escrowAddress: `0x${string}`,
    private makerAddress: `0x${string}`,
    private sourceChainId: number,
    private councilAddress: `0x${string}` | undefined,
  ) {}

  async start(pollIntervalMs: number): Promise<void> {
    this.canSoloResolve = await this.checkCouncilMembership();
    if (this.councilAddress && !this.canSoloResolve) {
      console.warn(
        "DisputeResponder: not a solo-capable council member — challenged fills " +
        "will need out-of-band council signatures to defend",
      );
    }

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

    // Poll for resolution retries and expired dispute finalization
    this.interval = setInterval(() => {
      this.enqueueWork(() => this.retryPendingResolutions());
      this.enqueueWork(() => this.finalizeExpiredDisputes());
    }, pollIntervalMs);

    console.log("DisputeResponder started (v2: defend + finalize)");
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

  /** Solo-capable = council member and threshold 1 (bootstrap council) */
  private async checkCouncilMembership(): Promise<boolean> {
    if (!this.councilAddress) return false;
    try {
      const [isMember, threshold] = await Promise.all([
        this.sourcePublicClient.readContract({
          address: this.councilAddress,
          abi: CouncilResolverAbi,
          functionName: "isMember",
          args: [this.makerAddress],
        }),
        this.sourcePublicClient.readContract({
          address: this.councilAddress,
          abi: CouncilResolverAbi,
          functionName: "threshold",
        }),
      ]);
      return Boolean(isMember) && (threshold as bigint) === 1n;
    } catch (err) {
      console.error("Failed to check council membership:", err);
      return false;
    }
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

    if (this.activeDisputes.has(intentId)) {
      return;
    }

    console.log(`DisputeRaised detected: ${intentId} by ${challenger}`);

    // Read commitment from escrow
    const commitment = await this.sourcePublicClient.readContract({
      address: this.escrowAddress,
      abi: GauloiEscrowAbi,
      functionName: "getCommitment",
      args: [intentId],
    });

    const fillTxHash = commitment.fillTxHash as `0x${string}`;
    const maker = commitment.maker as `0x${string}`;

    // Read dispute from disputes contract
    const dispute = await this.sourcePublicClient.readContract({
      address: this.disputesAddress,
      abi: GauloiDisputesAbi,
      functionName: "getDispute",
      args: [intentId],
    });

    const disputeDeadline = dispute.disputeDeadline as bigint;

    // Track for finalization regardless of role
    this.activeDisputes.set(intentId, {
      intentId,
      disputeDeadline,
      challenger,
      maker,
    });

    const weAreMaker = this.makerAddress.toLowerCase() === maker.toLowerCase();
    const weAreChallenger = this.makerAddress.toLowerCase() === challenger.toLowerCase();

    if (weAreChallenger) {
      // Our challenge — the deadline default is in our favor; just finalize later
      console.log(`Tracking our own challenge ${intentId} for finalization`);
      return;
    }

    // The order is stored on-chain by challenge(); read it back for verification
    const order = await this.readDisputeOrder(intentId, log.transactionHash);
    if (!order) {
      if (weAreMaker) {
        console.error(
          `CRITICAL: our fill ${intentId} is challenged and the order could not be ` +
          `recovered — undefended challenges resolve INVALID and slash our stake`,
        );
      }
      return;
    }

    // Verify the fill honestly — the council must never sign a verdict it
    // hasn't checked, even (especially) for our own fills
    let fillValid: boolean;
    if (fillTxHash === ZERO_BYTES32) {
      fillValid = false;
    } else {
      try {
        fillValid = await verifyFillOnDestination(this.destPublicClient, fillTxHash, order);
      } catch (err) {
        console.error(`Transient error verifying fill for ${intentId}:`, err);
        if (weAreMaker) {
          // Retry via the poll loop rather than dropping — defense is mandatory
          this.enqueueWork(() => this.handleRedelivery(intentId, log));
        }
        return;
      }
    }

    console.log(`Fill verification for ${intentId}: ${fillValid ? "valid" : "invalid"}`);

    if (weAreMaker && !fillValid) {
      console.error(
        `CRITICAL: our own challenged fill ${intentId} does not verify — ` +
        `it will resolve INVALID at the deadline and our stake will be slashed`,
      );
      return;
    }

    if (!this.canSoloResolve) {
      if (weAreMaker) {
        console.error(
          `CRITICAL: our fill ${intentId} is challenged (verified ${fillValid}) but this ` +
          `bot cannot submit a council verdict — obtain council signatures before ` +
          `deadline ${disputeDeadline} or the dispute resolves INVALID`,
        );
      }
      return;
    }

    // Bootstrap council path: sign the verdict and resolve
    const signature = await signCouncilVerdict(
      this.sourceWalletClient,
      { intentId, fillValid, destinationChainId: order.destinationChainId },
      this.councilAddress!,
      this.sourceChainId,
    );
    const evidence = encodeCouncilEvidence(fillValid, [signature]);

    await this.submitResolution(intentId, evidence);
  }

  /** Re-deliver a dispute whose verification hit a transient error */
  private async handleRedelivery(intentId: `0x${string}`, log: DisputeRaisedLog): Promise<void> {
    this.activeDisputes.delete(intentId);
    await this.handleDisputeRaised(log);
  }

  /** The challenged order is stored on-chain; fall back to challenge-tx calldata */
  private async readDisputeOrder(
    intentId: `0x${string}`,
    challengeTxHash: `0x${string}`,
  ): Promise<Order | null> {
    try {
      const stored = await this.sourcePublicClient.readContract({
        address: this.disputesAddress,
        abi: GauloiDisputesAbi,
        functionName: "getDisputeOrder",
        args: [intentId],
      });
      if (stored.taker !== "0x0000000000000000000000000000000000000000") {
        return stored as Order;
      }
    } catch {
      // fall through to calldata decode
    }

    try {
      const tx = await this.sourcePublicClient.getTransaction({ hash: challengeTxHash });
      const decoded = decodeFunctionData({ abi: GauloiDisputesAbi, data: tx.input });
      if (decoded.functionName !== "challenge") return null;
      return decoded.args[0] as Order;
    } catch (err) {
      console.error(`Failed to recover order for dispute ${intentId}:`, err);
      return null;
    }
  }

  private async submitResolution(intentId: `0x${string}`, evidence: `0x${string}`): Promise<void> {
    try {
      const hash = await this.sourceWalletClient.writeContract({
        address: this.disputesAddress,
        abi: GauloiDisputesAbi,
        functionName: "resolve",
        args: [intentId, evidence],
      });
      console.log(`Resolution submitted for ${intentId}: ${hash}`);
      this.pendingResolutions.delete(intentId);
    } catch (err) {
      const pending = this.pendingResolutions.get(intentId);
      const retries = pending ? pending.retries + 1 : 1;
      if (retries > MAX_RESOLUTION_RETRIES) {
        console.error(`Resolution for ${intentId} failed after ${MAX_RESOLUTION_RETRIES} retries, giving up`);
        this.pendingResolutions.delete(intentId);
      } else {
        console.error(`Failed to submit resolution for ${intentId} (attempt ${retries}/${MAX_RESOLUTION_RETRIES}):`, err);
        this.pendingResolutions.set(intentId, { intentId, evidence, retries });
      }
    }
  }

  async retryPendingResolutions(): Promise<void> {
    const pendingEntries = [...this.pendingResolutions.entries()];

    for (const [intentId, pending] of pendingEntries) {
      // Check if dispute is already resolved before retrying
      const dispute = await this.sourcePublicClient.readContract({
        address: this.disputesAddress,
        abi: GauloiDisputesAbi,
        functionName: "getDispute",
        args: [intentId as `0x${string}`],
      });

      if (dispute.resolved) {
        console.log(`Dispute ${intentId} already resolved, dropping pending resolution`);
        this.pendingResolutions.delete(intentId);
        continue;
      }

      await this.submitResolution(pending.intentId, pending.evidence);
    }
  }

  async finalizeExpiredDisputes(): Promise<void> {
    const now = BigInt(Math.floor(Date.now() / 1000));
    const entries = [...this.activeDisputes.entries()];

    for (const [intentId, tracked] of entries) {
      // Skip if deadline hasn't passed
      if (tracked.disputeDeadline > now) continue;

      // Read dispute on-chain to check current state
      const dispute = await this.sourcePublicClient.readContract({
        address: this.disputesAddress,
        abi: GauloiDisputesAbi,
        functionName: "getDispute",
        args: [intentId as `0x${string}`],
      });

      if (dispute.resolved) {
        this.activeDisputes.delete(intentId);
        continue;
      }

      // Attempt finalization — resolves INVALID (maker failed to defend)
      try {
        const hash = await this.sourceWalletClient.writeContract({
          address: this.disputesAddress,
          abi: GauloiDisputesAbi,
          functionName: "finalizeExpiredDispute",
          args: [intentId as `0x${string}`],
        });
        console.log(`Finalized expired dispute ${intentId}: ${hash}`);
        await this.sourcePublicClient.waitForTransactionReceipt({ hash });
        this.activeDisputes.delete(intentId);
      } catch (err) {
        console.error(`Failed to finalize dispute ${intentId}:`, err);
      }
    }
  }
}
