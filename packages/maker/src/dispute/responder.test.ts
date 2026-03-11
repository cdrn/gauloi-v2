import { describe, it, expect, vi, beforeEach } from "vitest";
import { encodeFunctionData } from "viem";
import { GauloiDisputesAbi } from "@gauloi/common";
import { DisputeResponder } from "./responder.js";

// Mock signAttestation
vi.mock("@gauloi/common", async () => {
  const actual = await vi.importActual("@gauloi/common");
  return {
    ...actual,
    signAttestation: vi.fn().mockResolvedValue("0xMOCK_ATTESTATION_SIG"),
  };
});

// Mock verifyFillOnDestination
vi.mock("./verify-fill.js", () => ({
  verifyFillOnDestination: vi.fn().mockResolvedValue(true),
}));

import { signAttestation } from "@gauloi/common";
import { verifyFillOnDestination } from "./verify-fill.js";

// --- helpers ---

const DISPUTES = "0xcccccccccccccccccccccccccccccccccccccccc" as `0x${string}`;
const ESCROW = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" as `0x${string}`;
const MAKER = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" as `0x${string}`;
const OTHER_MAKER = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" as `0x${string}`;
const CHALLENGER = "0xdddddddddddddddddddddddddddddddddddddd" as `0x${string}`;
const INTENT_ID = "0x1111111111111111111111111111111111111111111111111111111111111111" as `0x${string}`;
const FILL_TX_HASH = "0x2222222222222222222222222222222222222222222222222222222222222222" as `0x${string}`;
const CHAIN_ID = 11155111;

const mockOrder = {
  taker: "0x1111111111111111111111111111111111111111" as `0x${string}`,
  inputToken: "0x2222222222222222222222222222222222222222" as `0x${string}`,
  inputAmount: 1_000_000n,
  outputToken: "0x3333333333333333333333333333333333333333" as `0x${string}`,
  minOutputAmount: 990_000n,
  destinationChainId: 421614n,
  destinationAddress: "0x1111111111111111111111111111111111111111" as `0x${string}`,
  expiry: BigInt(Math.floor(Date.now() / 1000) + 3600),
  nonce: 1n,
};

function makeDisputeTxInput() {
  return encodeFunctionData({
    abi: GauloiDisputesAbi,
    functionName: "dispute",
    args: [mockOrder],
  });
}

function makeDisputeRaisedLog(overrides: Record<string, any> = {}) {
  return {
    transactionHash: "0xDISPUTE_TX_HASH" as `0x${string}`,
    args: {
      intentId: INTENT_ID,
      challenger: CHALLENGER,
      bondAmount: 100_000n,
      ...overrides,
    },
  };
}

const ZERO_HASH = "0x0000000000000000000000000000000000000000000000000000000000000000" as `0x${string}`;

const INTENT_ID_2 = "0x4444444444444444444444444444444444444444444444444444444444444444" as `0x${string}`;

function createMocks() {
  const futureDeadline = BigInt(Math.floor(Date.now() / 1000) + 3600);

  const sourcePublicClient = {
    readContract: vi.fn().mockImplementation(({ functionName }: any) => {
      if (functionName === "getCommitment") {
        return Promise.resolve({
          fillTxHash: FILL_TX_HASH,
          maker: OTHER_MAKER,
          taker: mockOrder.taker,
          state: 3, // Disputed
        });
      }
      if (functionName === "getDispute") {
        return Promise.resolve({
          intentId: INTENT_ID,
          challenger: CHALLENGER,
          bondAmount: 100_000n,
          disputeDeadline: futureDeadline,
          resolved: false,
          fillDeemedValid: false,
        });
      }
      return Promise.resolve(null);
    }),
    getTransaction: vi.fn().mockResolvedValue({
      input: makeDisputeTxInput(),
    }),
    watchContractEvent: vi.fn().mockReturnValue(() => {}),
    waitForTransactionReceipt: vi.fn().mockResolvedValue({ status: "success" }),
  } as any;

  const sourceWalletClient = {
    writeContract: vi.fn().mockResolvedValue("0xATTESTATION_TX"),
    account: { address: MAKER },
    signTypedData: vi.fn().mockResolvedValue("0xSIG"),
  } as any;

  const destPublicClient = {
    getTransactionReceipt: vi.fn().mockResolvedValue({
      status: "success",
      logs: [],
    }),
  } as any;

  return { sourcePublicClient, sourceWalletClient, destPublicClient };
}

// --- tests ---

describe("DisputeResponder", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    (verifyFillOnDestination as any).mockResolvedValue(true);
  });

  it("handles DisputeRaised: verifies, signs, and submits attestation", async () => {
    const { sourcePublicClient, sourceWalletClient, destPublicClient } = createMocks();

    const responder = new DisputeResponder(
      sourcePublicClient,
      sourceWalletClient,
      destPublicClient,
      DISPUTES,
      ESCROW,
      MAKER,
      CHAIN_ID,
    );

    await responder.handleDisputeRaised(makeDisputeRaisedLog());

    // Should have verified the fill
    expect(verifyFillOnDestination).toHaveBeenCalledWith(
      destPublicClient,
      FILL_TX_HASH,
      expect.objectContaining({ taker: mockOrder.taker }),
    );

    // Should have signed attestation
    expect(signAttestation).toHaveBeenCalledWith(
      sourceWalletClient,
      expect.objectContaining({
        intentId: INTENT_ID,
        fillValid: true,
        fillTxHash: FILL_TX_HASH,
      }),
      DISPUTES,
      CHAIN_ID,
    );

    // Should have submitted on-chain
    expect(sourceWalletClient.writeContract).toHaveBeenCalledWith(
      expect.objectContaining({
        functionName: "resolveDispute",
        args: [INTENT_ID, true, ["0xMOCK_ATTESTATION_SIG"]],
      }),
    );
  });

  it("skips attestation when we are the disputed maker", async () => {
    const { sourcePublicClient, sourceWalletClient, destPublicClient } = createMocks();

    // Make us the disputed maker
    sourcePublicClient.readContract.mockImplementation(({ functionName }: any) => {
      if (functionName === "getCommitment") {
        return Promise.resolve({
          fillTxHash: FILL_TX_HASH,
          maker: MAKER, // <-- we are the maker
          taker: mockOrder.taker,
          state: 3,
        });
      }
      if (functionName === "getDispute") {
        return Promise.resolve({
          intentId: INTENT_ID,
          challenger: CHALLENGER,
          disputeDeadline: BigInt(Math.floor(Date.now() / 1000) + 3600),
          resolved: false,
        });
      }
      return Promise.resolve(null);
    });

    const responder = new DisputeResponder(
      sourcePublicClient,
      sourceWalletClient,
      destPublicClient,
      DISPUTES,
      ESCROW,
      MAKER,
      CHAIN_ID,
    );

    await responder.handleDisputeRaised(makeDisputeRaisedLog());

    // Should NOT verify or submit
    expect(verifyFillOnDestination).not.toHaveBeenCalled();
    expect(sourceWalletClient.writeContract).not.toHaveBeenCalled();
  });

  it("skips attestation when we are the challenger", async () => {
    const { sourcePublicClient, sourceWalletClient, destPublicClient } = createMocks();

    const responder = new DisputeResponder(
      sourcePublicClient,
      sourceWalletClient,
      destPublicClient,
      DISPUTES,
      ESCROW,
      CHALLENGER, // <-- we are the challenger
      CHAIN_ID,
    );

    await responder.handleDisputeRaised(makeDisputeRaisedLog());

    expect(verifyFillOnDestination).not.toHaveBeenCalled();
    expect(sourceWalletClient.writeContract).not.toHaveBeenCalled();
  });

  it("finalizes expired disputes", async () => {
    const { sourcePublicClient, sourceWalletClient, destPublicClient } = createMocks();

    const pastDeadline = BigInt(Math.floor(Date.now() / 1000) - 100);

    const responder = new DisputeResponder(
      sourcePublicClient,
      sourceWalletClient,
      destPublicClient,
      DISPUTES,
      ESCROW,
      MAKER,
      CHAIN_ID,
    );

    // Manually inject a tracked dispute with expired deadline
    (responder as any).activeDisputes.set(INTENT_ID, {
      intentId: INTENT_ID,
      disputeDeadline: pastDeadline,
      challenger: CHALLENGER,
      maker: OTHER_MAKER,
    });

    // Mock getDispute to return unresolved then resolved
    let callCount = 0;
    sourcePublicClient.readContract.mockImplementation(({ functionName }: any) => {
      if (functionName === "getDispute") {
        callCount++;
        if (callCount === 1) {
          return Promise.resolve({ resolved: false, disputeDeadline: pastDeadline });
        }
        return Promise.resolve({ resolved: true, disputeDeadline: pastDeadline });
      }
      return Promise.resolve(null);
    });

    await responder.finalizeExpiredDisputes();

    expect(sourceWalletClient.writeContract).toHaveBeenCalledWith(
      expect.objectContaining({
        functionName: "finalizeExpiredDispute",
        args: [INTENT_ID],
      }),
    );

    // Should remove from tracking after resolution
    expect((responder as any).activeDisputes.has(INTENT_ID)).toBe(false);
  });

  it("removes resolved disputes from tracking", async () => {
    const { sourcePublicClient, sourceWalletClient, destPublicClient } = createMocks();

    const pastDeadline = BigInt(Math.floor(Date.now() / 1000) - 100);

    const responder = new DisputeResponder(
      sourcePublicClient,
      sourceWalletClient,
      destPublicClient,
      DISPUTES,
      ESCROW,
      MAKER,
      CHAIN_ID,
    );

    (responder as any).activeDisputes.set(INTENT_ID, {
      intentId: INTENT_ID,
      disputeDeadline: pastDeadline,
      challenger: CHALLENGER,
      maker: OTHER_MAKER,
    });

    // Already resolved on first read
    sourcePublicClient.readContract.mockImplementation(({ functionName }: any) => {
      if (functionName === "getDispute") {
        return Promise.resolve({ resolved: true, disputeDeadline: pastDeadline });
      }
      return Promise.resolve(null);
    });

    await responder.finalizeExpiredDisputes();

    // Should NOT attempt to finalize
    expect(sourceWalletClient.writeContract).not.toHaveBeenCalled();
    // Should remove from tracking
    expect((responder as any).activeDisputes.has(INTENT_ID)).toBe(false);
  });

  it("handles quorum extension (deadline update)", async () => {
    const { sourcePublicClient, sourceWalletClient, destPublicClient } = createMocks();

    const pastDeadline = BigInt(Math.floor(Date.now() / 1000) - 100);
    const newDeadline = BigInt(Math.floor(Date.now() / 1000) + 3600);

    const responder = new DisputeResponder(
      sourcePublicClient,
      sourceWalletClient,
      destPublicClient,
      DISPUTES,
      ESCROW,
      MAKER,
      CHAIN_ID,
    );

    (responder as any).activeDisputes.set(INTENT_ID, {
      intentId: INTENT_ID,
      disputeDeadline: pastDeadline,
      challenger: CHALLENGER,
      maker: OTHER_MAKER,
    });

    // Both reads return unresolved but with different deadlines (quorum extension)
    let callCount = 0;
    sourcePublicClient.readContract.mockImplementation(({ functionName }: any) => {
      if (functionName === "getDispute") {
        callCount++;
        if (callCount === 1) {
          return Promise.resolve({ resolved: false, disputeDeadline: pastDeadline });
        }
        return Promise.resolve({ resolved: false, disputeDeadline: newDeadline });
      }
      return Promise.resolve(null);
    });

    await responder.finalizeExpiredDisputes();

    // Should have attempted finalization
    expect(sourceWalletClient.writeContract).toHaveBeenCalled();

    // Should still be tracked with updated deadline
    const tracked = (responder as any).activeDisputes.get(INTENT_ID);
    expect(tracked).toBeDefined();
    expect(tracked.disputeDeadline).toBe(newDeadline);
  });

  it("processes multiple DisputeRaised logs sequentially (no nonce collision)", async () => {
    const { sourcePublicClient, sourceWalletClient, destPublicClient } = createMocks();

    // Track call order to prove sequential execution
    const callOrder: string[] = [];
    const originalWriteContract = sourceWalletClient.writeContract;
    sourceWalletClient.writeContract = vi.fn().mockImplementation(async (args: any) => {
      callOrder.push(args.args[0]); // intentId
      // Simulate tx latency — if concurrent, both would start before either finishes
      await new Promise((r) => setTimeout(r, 20));
      return originalWriteContract(args);
    });

    // Return different commitments per intentId
    sourcePublicClient.readContract.mockImplementation(({ functionName, args }: any) => {
      if (functionName === "getCommitment") {
        return Promise.resolve({
          fillTxHash: FILL_TX_HASH,
          maker: OTHER_MAKER,
          taker: mockOrder.taker,
          state: 3,
        });
      }
      if (functionName === "getDispute") {
        return Promise.resolve({
          intentId: args[0],
          challenger: CHALLENGER,
          bondAmount: 100_000n,
          disputeDeadline: BigInt(Math.floor(Date.now() / 1000) + 3600),
          resolved: false,
          fillDeemedValid: false,
        });
      }
      return Promise.resolve(null);
    });

    const responder = new DisputeResponder(
      sourcePublicClient,
      sourceWalletClient,
      destPublicClient,
      DISPUTES,
      ESCROW,
      MAKER,
      CHAIN_ID,
    );

    const log1 = makeDisputeRaisedLog({ intentId: INTENT_ID });
    const log2 = makeDisputeRaisedLog({ intentId: INTENT_ID_2 });

    // Enqueue both logs simultaneously (simulates a block with 2 DisputeRaised events)
    (responder as any).enqueueWork(() => responder.handleDisputeRaised(log1));
    (responder as any).enqueueWork(() => responder.handleDisputeRaised(log2));

    // Wait for queue to drain
    await new Promise((r) => setTimeout(r, 200));

    // Both should have been processed
    expect(sourceWalletClient.writeContract).toHaveBeenCalledTimes(2);

    // Should have been processed in order (sequential, not concurrent)
    expect(callOrder).toEqual([INTENT_ID, INTENT_ID_2]);
  });

  it("attests as invalid when fillTxHash is zero (no fill evidence)", async () => {
    const { sourcePublicClient, sourceWalletClient, destPublicClient } = createMocks();

    // Return zero fillTxHash from commitment
    sourcePublicClient.readContract.mockImplementation(({ functionName }: any) => {
      if (functionName === "getCommitment") {
        return Promise.resolve({
          fillTxHash: ZERO_HASH,
          maker: OTHER_MAKER,
          taker: mockOrder.taker,
          state: 3,
        });
      }
      if (functionName === "getDispute") {
        return Promise.resolve({
          intentId: INTENT_ID,
          challenger: CHALLENGER,
          bondAmount: 100_000n,
          disputeDeadline: BigInt(Math.floor(Date.now() / 1000) + 3600),
          resolved: false,
          fillDeemedValid: false,
        });
      }
      return Promise.resolve(null);
    });

    const responder = new DisputeResponder(
      sourcePublicClient,
      sourceWalletClient,
      destPublicClient,
      DISPUTES,
      ESCROW,
      MAKER,
      CHAIN_ID,
    );

    await responder.handleDisputeRaised(makeDisputeRaisedLog());

    // Should NOT try to verify fill on destination chain
    expect(verifyFillOnDestination).not.toHaveBeenCalled();

    // Should sign attestation with fillValid=false and the order's real destinationChainId
    expect(signAttestation).toHaveBeenCalledWith(
      sourceWalletClient,
      expect.objectContaining({
        intentId: INTENT_ID,
        fillValid: false,
        fillTxHash: ZERO_HASH,
        destinationChainId: mockOrder.destinationChainId,
      }),
      DISPUTES,
      CHAIN_ID,
    );

    // Should submit on-chain with fillValid=false
    expect(sourceWalletClient.writeContract).toHaveBeenCalledWith(
      expect.objectContaining({
        functionName: "resolveDispute",
        args: [INTENT_ID, false, expect.any(Array)],
      }),
    );
  });

  it("attests as invalid when verifyFillOnDestination returns false", async () => {
    const { sourcePublicClient, sourceWalletClient, destPublicClient } = createMocks();

    // Fill verification fails
    (verifyFillOnDestination as any).mockResolvedValue(false);

    const responder = new DisputeResponder(
      sourcePublicClient,
      sourceWalletClient,
      destPublicClient,
      DISPUTES,
      ESCROW,
      MAKER,
      CHAIN_ID,
    );

    await responder.handleDisputeRaised(makeDisputeRaisedLog());

    // Should have verified the fill
    expect(verifyFillOnDestination).toHaveBeenCalled();

    // Should sign attestation with fillValid=false
    expect(signAttestation).toHaveBeenCalledWith(
      sourceWalletClient,
      expect.objectContaining({
        intentId: INTENT_ID,
        fillValid: false,
        fillTxHash: FILL_TX_HASH,
      }),
      DISPUTES,
      CHAIN_ID,
    );

    // Should submit on-chain with fillValid=false
    expect(sourceWalletClient.writeContract).toHaveBeenCalledWith(
      expect.objectContaining({
        functionName: "resolveDispute",
        args: [INTENT_ID, false, ["0xMOCK_ATTESTATION_SIG"]],
      }),
    );
  });

  it("returns early when getTransaction fails (cannot decode order)", async () => {
    const { sourcePublicClient, sourceWalletClient, destPublicClient } = createMocks();

    // getTransaction throws (tx not yet indexed)
    sourcePublicClient.getTransaction.mockRejectedValue(new Error("tx not found"));

    const responder = new DisputeResponder(
      sourcePublicClient,
      sourceWalletClient,
      destPublicClient,
      DISPUTES,
      ESCROW,
      MAKER,
      CHAIN_ID,
    );

    await responder.handleDisputeRaised(makeDisputeRaisedLog());

    // Should NOT attempt verification or attestation submission
    expect(verifyFillOnDestination).not.toHaveBeenCalled();
    expect(sourceWalletClient.writeContract).not.toHaveBeenCalled();
  });

  it("still tracks dispute and queues retry when attestation submission reverts", async () => {
    const { sourcePublicClient, sourceWalletClient, destPublicClient } = createMocks();

    // writeContract reverts
    sourceWalletClient.writeContract.mockRejectedValue(new Error("execution reverted"));

    const responder = new DisputeResponder(
      sourcePublicClient,
      sourceWalletClient,
      destPublicClient,
      DISPUTES,
      ESCROW,
      MAKER,
      CHAIN_ID,
    );

    await responder.handleDisputeRaised(makeDisputeRaisedLog());

    // Attestation was attempted
    expect(sourceWalletClient.writeContract).toHaveBeenCalled();

    // Dispute should still be tracked for finalization
    expect((responder as any).activeDisputes.has(INTENT_ID)).toBe(true);

    // Attestation should be queued for retry
    const pending = (responder as any).pendingAttestations.get(INTENT_ID);
    expect(pending).toBeDefined();
    expect(pending.fillValid).toBe(true);
    expect(pending.retries).toBe(1);
    expect(pending.signature).toBe("0xMOCK_ATTESTATION_SIG");
  });

  it("retryPendingAttestations resubmits on next poll", async () => {
    const { sourcePublicClient, sourceWalletClient, destPublicClient } = createMocks();

    const responder = new DisputeResponder(
      sourcePublicClient,
      sourceWalletClient,
      destPublicClient,
      DISPUTES,
      ESCROW,
      MAKER,
      CHAIN_ID,
    );

    // Inject a pending attestation (simulating a prior failure)
    (responder as any).pendingAttestations.set(INTENT_ID, {
      intentId: INTENT_ID,
      fillValid: true,
      signature: "0xMOCK_ATTESTATION_SIG" as `0x${string}`,
      retries: 1,
    });

    // Mock dispute as unresolved
    sourcePublicClient.readContract.mockImplementation(({ functionName }: any) => {
      if (functionName === "getDispute") {
        return Promise.resolve({ resolved: false });
      }
      return Promise.resolve(null);
    });

    await responder.retryPendingAttestations();

    // Should have resubmitted
    expect(sourceWalletClient.writeContract).toHaveBeenCalledWith(
      expect.objectContaining({
        functionName: "resolveDispute",
        args: [INTENT_ID, true, ["0xMOCK_ATTESTATION_SIG"]],
      }),
    );

    // Should clear pending on success
    expect((responder as any).pendingAttestations.has(INTENT_ID)).toBe(false);
  });

  it("retryPendingAttestations drops attestation if dispute already resolved", async () => {
    const { sourcePublicClient, sourceWalletClient, destPublicClient } = createMocks();

    const responder = new DisputeResponder(
      sourcePublicClient,
      sourceWalletClient,
      destPublicClient,
      DISPUTES,
      ESCROW,
      MAKER,
      CHAIN_ID,
    );

    (responder as any).pendingAttestations.set(INTENT_ID, {
      intentId: INTENT_ID,
      fillValid: true,
      signature: "0xMOCK_ATTESTATION_SIG" as `0x${string}`,
      retries: 1,
    });

    // Dispute already resolved
    sourcePublicClient.readContract.mockImplementation(({ functionName }: any) => {
      if (functionName === "getDispute") {
        return Promise.resolve({ resolved: true });
      }
      return Promise.resolve(null);
    });

    await responder.retryPendingAttestations();

    // Should NOT attempt resubmission
    expect(sourceWalletClient.writeContract).not.toHaveBeenCalled();

    // Should clear pending
    expect((responder as any).pendingAttestations.has(INTENT_ID)).toBe(false);
  });

  it("gives up after MAX_ATTESTATION_RETRIES", async () => {
    const { sourcePublicClient, sourceWalletClient, destPublicClient } = createMocks();

    // Always revert
    sourceWalletClient.writeContract.mockRejectedValue(new Error("execution reverted"));

    const responder = new DisputeResponder(
      sourcePublicClient,
      sourceWalletClient,
      destPublicClient,
      DISPUTES,
      ESCROW,
      MAKER,
      CHAIN_ID,
    );

    // Inject at retry 5 (MAX_ATTESTATION_RETRIES)
    (responder as any).pendingAttestations.set(INTENT_ID, {
      intentId: INTENT_ID,
      fillValid: true,
      signature: "0xMOCK_ATTESTATION_SIG" as `0x${string}`,
      retries: 5,
    });

    sourcePublicClient.readContract.mockImplementation(({ functionName }: any) => {
      if (functionName === "getDispute") {
        return Promise.resolve({ resolved: false });
      }
      return Promise.resolve(null);
    });

    await responder.retryPendingAttestations();

    // Should have attempted but failed
    expect(sourceWalletClient.writeContract).toHaveBeenCalled();

    // Should be removed after exceeding max retries
    expect((responder as any).pendingAttestations.has(INTENT_ID)).toBe(false);
  });

  it("increments retry count on repeated failures", async () => {
    const { sourcePublicClient, sourceWalletClient, destPublicClient } = createMocks();

    // Always revert
    sourceWalletClient.writeContract.mockRejectedValue(new Error("execution reverted"));

    const responder = new DisputeResponder(
      sourcePublicClient,
      sourceWalletClient,
      destPublicClient,
      DISPUTES,
      ESCROW,
      MAKER,
      CHAIN_ID,
    );

    // First failure from handleDisputeRaised
    await responder.handleDisputeRaised(makeDisputeRaisedLog());

    let pending = (responder as any).pendingAttestations.get(INTENT_ID);
    expect(pending.retries).toBe(1);

    // Simulate retry via retryPendingAttestations
    sourcePublicClient.readContract.mockImplementation(({ functionName }: any) => {
      if (functionName === "getCommitment") {
        return Promise.resolve({
          fillTxHash: FILL_TX_HASH,
          maker: OTHER_MAKER,
          taker: mockOrder.taker,
          state: 3,
        });
      }
      if (functionName === "getDispute") {
        return Promise.resolve({
          resolved: false,
          disputeDeadline: BigInt(Math.floor(Date.now() / 1000) + 3600),
        });
      }
      return Promise.resolve(null);
    });

    await responder.retryPendingAttestations();

    pending = (responder as any).pendingAttestations.get(INTENT_ID);
    expect(pending.retries).toBe(2);

    // Still tracked
    expect((responder as any).pendingAttestations.has(INTENT_ID)).toBe(true);
  });

  it("waits for tx confirmation before re-reading state in finalizeExpiredDisputes", async () => {
    const { sourcePublicClient, sourceWalletClient, destPublicClient } = createMocks();

    const pastDeadline = BigInt(Math.floor(Date.now() / 1000) - 100);

    const responder = new DisputeResponder(
      sourcePublicClient,
      sourceWalletClient,
      destPublicClient,
      DISPUTES,
      ESCROW,
      MAKER,
      CHAIN_ID,
    );

    (responder as any).activeDisputes.set(INTENT_ID, {
      intentId: INTENT_ID,
      disputeDeadline: pastDeadline,
      challenger: CHALLENGER,
      maker: OTHER_MAKER,
    });

    // Track call ordering to verify waitForTransactionReceipt is called
    // before the second readContract
    const callOrder: string[] = [];

    let readCount = 0;
    sourcePublicClient.readContract.mockImplementation(({ functionName }: any) => {
      if (functionName === "getDispute") {
        readCount++;
        callOrder.push(`readContract:${readCount}`);
        if (readCount === 1) {
          return Promise.resolve({ resolved: false, disputeDeadline: pastDeadline });
        }
        return Promise.resolve({ resolved: true, disputeDeadline: pastDeadline });
      }
      return Promise.resolve(null);
    });

    sourcePublicClient.waitForTransactionReceipt.mockImplementation(async () => {
      callOrder.push("waitForTransactionReceipt");
      return { status: "success" };
    });

    sourceWalletClient.writeContract.mockImplementation(async () => {
      callOrder.push("writeContract");
      return "0xFINALIZE_TX";
    });

    await responder.finalizeExpiredDisputes();

    // Verify ordering: first read -> writeContract -> waitForReceipt -> second read
    expect(callOrder).toEqual([
      "readContract:1",
      "writeContract",
      "waitForTransactionReceipt",
      "readContract:2",
    ]);
  });
});
