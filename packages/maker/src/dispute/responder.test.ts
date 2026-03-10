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
    address: DISPUTES,
    blockHash: "0x0000000000000000000000000000000000000000000000000000000000000000" as `0x${string}`,
    blockNumber: 100n,
    data: "0x" as `0x${string}`,
    topics: [] as [],
    logIndex: 0,
    transactionHash: "0xDISPUTE_TX_HASH" as `0x${string}`,
    transactionIndex: 0,
    removed: false,
    args: {
      intentId: INTENT_ID,
      challenger: CHALLENGER,
      bondAmount: 100_000n,
      ...overrides,
    },
  };
}

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
});
