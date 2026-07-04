import { describe, it, expect, vi, beforeEach } from "vitest";
import { ZERO_BYTES32, encodeCouncilEvidence } from "@gauloi/common";
import { DisputeResponder } from "./responder.js";

// Mock verifyFillOnDestination
vi.mock("./verify-fill.js", () => ({
  verifyFillOnDestination: vi.fn().mockResolvedValue(true),
}));

import { verifyFillOnDestination } from "./verify-fill.js";

// --- helpers ---

const DISPUTES = "0xcccccccccccccccccccccccccccccccccccccccc" as `0x${string}`;
const ESCROW = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" as `0x${string}`;
const COUNCIL = "0x9999999999999999999999999999999999999999" as `0x${string}`;
const MAKER = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" as `0x${string}`;
const OTHER_MAKER = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" as `0x${string}`;
const CHALLENGER = "0xdddddddddddddddddddddddddddddddddddddd" as `0x${string}`;
const INTENT_ID = "0x1111111111111111111111111111111111111111111111111111111111111111" as `0x${string}`;
const FILL_TX_HASH = "0x2222222222222222222222222222222222222222222222222222222222222222" as `0x${string}`;
const CHAIN_ID = 11155111;
const SIG = "0xSIG" as `0x${string}`;

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

function makeDisputeRaisedLog(overrides: Record<string, any> = {}) {
  return {
    transactionHash: "0xCHALLENGE_TX_HASH" as `0x${string}`,
    args: {
      intentId: INTENT_ID,
      challenger: CHALLENGER,
      bondAmount: 100_000n,
      ...overrides,
    },
  };
}

interface MockOptions {
  disputedMaker?: `0x${string}`;
  fillTxHash?: `0x${string}`;
  isMember?: boolean;
  threshold?: bigint;
  disputeDeadline?: bigint;
  resolved?: boolean;
}

function createMocks(opts: MockOptions = {}) {
  const {
    disputedMaker = OTHER_MAKER,
    fillTxHash = FILL_TX_HASH,
    isMember = true,
    threshold = 1n,
    disputeDeadline = BigInt(Math.floor(Date.now() / 1000) + 3600),
    resolved = false,
  } = opts;

  const sourcePublicClient = {
    readContract: vi.fn().mockImplementation(({ functionName }: any) => {
      if (functionName === "getCommitment") {
        return Promise.resolve({
          fillTxHash,
          maker: disputedMaker,
          taker: mockOrder.taker,
          state: 3, // Disputed
        });
      }
      if (functionName === "getDispute") {
        return Promise.resolve({
          intentId: INTENT_ID,
          challenger: CHALLENGER,
          bondAmount: 100_000n,
          disputeDeadline,
          resolved,
          fillDeemedValid: false,
        });
      }
      if (functionName === "getDisputeOrder") {
        return Promise.resolve(mockOrder);
      }
      if (functionName === "isMember") {
        return Promise.resolve(isMember);
      }
      if (functionName === "threshold") {
        return Promise.resolve(threshold);
      }
      return Promise.resolve(null);
    }),
    getTransaction: vi.fn(),
    watchContractEvent: vi.fn().mockReturnValue(() => {}),
    waitForTransactionReceipt: vi.fn().mockResolvedValue({ status: "success" }),
  } as any;

  const sourceWalletClient = {
    writeContract: vi.fn().mockResolvedValue("0xRESOLVE_TX"),
    account: { address: MAKER },
    signTypedData: vi.fn().mockResolvedValue(SIG),
  } as any;

  const destPublicClient = {
    getTransactionReceipt: vi.fn().mockResolvedValue({ status: "success", logs: [] }),
  } as any;

  return { sourcePublicClient, sourceWalletClient, destPublicClient };
}

async function makeResponder(mocks: ReturnType<typeof createMocks>) {
  const responder = new DisputeResponder(
    mocks.sourcePublicClient,
    mocks.sourceWalletClient,
    mocks.destPublicClient,
    DISPUTES,
    ESCROW,
    MAKER,
    CHAIN_ID,
    COUNCIL,
  );
  await responder.start(1_000_000_000); // huge interval — we drive manually
  responder.stop();
  return responder;
}

function resolveCalls(walletClient: any) {
  return walletClient.writeContract.mock.calls.filter(
    (c: any[]) => c[0].functionName === "resolve",
  );
}

// --- tests ---

describe("DisputeResponder (v2)", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    (verifyFillOnDestination as any).mockResolvedValue(true);
  });

  it("resolves a third-party dispute through the bootstrap council after honest verification", async () => {
    const mocks = createMocks();
    const responder = await makeResponder(mocks);

    await responder.handleDisputeRaised(makeDisputeRaisedLog());

    expect(verifyFillOnDestination).toHaveBeenCalledWith(
      mocks.destPublicClient, FILL_TX_HASH, mockOrder,
    );

    const calls = resolveCalls(mocks.sourceWalletClient);
    expect(calls).toHaveLength(1);
    expect(calls[0][0].args).toEqual([INTENT_ID, encodeCouncilEvidence(true, [SIG])]);
  });

  it("defends our own challenged fill when it verifies", async () => {
    const mocks = createMocks({ disputedMaker: MAKER });
    const responder = await makeResponder(mocks);

    await responder.handleDisputeRaised(makeDisputeRaisedLog());

    const calls = resolveCalls(mocks.sourceWalletClient);
    expect(calls).toHaveLength(1);
    expect(calls[0][0].args).toEqual([INTENT_ID, encodeCouncilEvidence(true, [SIG])]);
  });

  it("never signs a verdict for our own fill that fails verification", async () => {
    (verifyFillOnDestination as any).mockResolvedValue(false);
    const mocks = createMocks({ disputedMaker: MAKER });
    const responder = await makeResponder(mocks);

    await responder.handleDisputeRaised(makeDisputeRaisedLog());

    expect(resolveCalls(mocks.sourceWalletClient)).toHaveLength(0);
  });

  it("submits an invalid verdict when there is no fill evidence", async () => {
    const mocks = createMocks({ fillTxHash: ZERO_BYTES32 });
    const responder = await makeResponder(mocks);

    await responder.handleDisputeRaised(makeDisputeRaisedLog());

    const calls = resolveCalls(mocks.sourceWalletClient);
    expect(calls).toHaveLength(1);
    expect(calls[0][0].args).toEqual([INTENT_ID, encodeCouncilEvidence(false, [SIG])]);
    expect(verifyFillOnDestination).not.toHaveBeenCalled();
  });

  it("only tracks our own challenges — the deadline default is in our favor", async () => {
    const mocks = createMocks();
    const responder = await makeResponder(mocks);

    await responder.handleDisputeRaised(makeDisputeRaisedLog({ challenger: MAKER }));

    expect(verifyFillOnDestination).not.toHaveBeenCalled();
    expect(resolveCalls(mocks.sourceWalletClient)).toHaveLength(0);
  });

  it("does not submit verdicts when not a solo-capable council member", async () => {
    const mocks = createMocks({ isMember: false });
    const responder = await makeResponder(mocks);

    await responder.handleDisputeRaised(makeDisputeRaisedLog());

    expect(resolveCalls(mocks.sourceWalletClient)).toHaveLength(0);
  });

  it("does not solo-resolve when council threshold > 1", async () => {
    const mocks = createMocks({ threshold: 2n });
    const responder = await makeResponder(mocks);

    await responder.handleDisputeRaised(makeDisputeRaisedLog());

    expect(resolveCalls(mocks.sourceWalletClient)).toHaveLength(0);
  });

  it("deduplicates re-delivered DisputeRaised events", async () => {
    const mocks = createMocks();
    const responder = await makeResponder(mocks);

    await responder.handleDisputeRaised(makeDisputeRaisedLog());
    await responder.handleDisputeRaised(makeDisputeRaisedLog());

    expect(resolveCalls(mocks.sourceWalletClient)).toHaveLength(1);
  });

  it("retries failed resolutions and drops them once the dispute is resolved", async () => {
    const mocks = createMocks();
    mocks.sourceWalletClient.writeContract.mockRejectedValueOnce(new Error("nonce too low"));
    const responder = await makeResponder(mocks);

    await responder.handleDisputeRaised(makeDisputeRaisedLog());
    expect(resolveCalls(mocks.sourceWalletClient)).toHaveLength(1); // failed attempt

    // Retry succeeds
    await responder.retryPendingResolutions();
    expect(resolveCalls(mocks.sourceWalletClient)).toHaveLength(2);

    // Nothing left pending
    await responder.retryPendingResolutions();
    expect(resolveCalls(mocks.sourceWalletClient)).toHaveLength(2);
  });

  it("drops pending resolutions for already-resolved disputes", async () => {
    const mocks = createMocks();
    mocks.sourceWalletClient.writeContract.mockRejectedValueOnce(new Error("boom"));
    const responder = await makeResponder(mocks);

    await responder.handleDisputeRaised(makeDisputeRaisedLog());

    // Dispute resolves out from under us
    mocks.sourcePublicClient.readContract.mockImplementation(({ functionName }: any) => {
      if (functionName === "getDispute") {
        return Promise.resolve({ resolved: true, disputeDeadline: 0n });
      }
      return Promise.resolve(null);
    });

    await responder.retryPendingResolutions();
    expect(resolveCalls(mocks.sourceWalletClient)).toHaveLength(1); // no retry
  });

  it("finalizes expired disputes (resolves invalid — maker failed to defend)", async () => {
    const past = BigInt(Math.floor(Date.now() / 1000) - 10);
    const mocks = createMocks({ disputeDeadline: past, isMember: false });
    const responder = await makeResponder(mocks);

    // Track a dispute we challenged
    await responder.handleDisputeRaised(makeDisputeRaisedLog({ challenger: MAKER }));

    await responder.finalizeExpiredDisputes();

    const finalizeCalls = mocks.sourceWalletClient.writeContract.mock.calls.filter(
      (c: any[]) => c[0].functionName === "finalizeExpiredDispute",
    );
    expect(finalizeCalls).toHaveLength(1);
    expect(finalizeCalls[0][0].args).toEqual([INTENT_ID]);
  });

  it("skips finalization for already-resolved disputes", async () => {
    const past = BigInt(Math.floor(Date.now() / 1000) - 10);
    const mocks = createMocks({ disputeDeadline: past, resolved: true, isMember: false });
    const responder = await makeResponder(mocks);

    await responder.handleDisputeRaised(makeDisputeRaisedLog({ challenger: MAKER }));
    await responder.finalizeExpiredDisputes();

    const finalizeCalls = mocks.sourceWalletClient.writeContract.mock.calls.filter(
      (c: any[]) => c[0].functionName === "finalizeExpiredDispute",
    );
    expect(finalizeCalls).toHaveLength(0);
  });
});
