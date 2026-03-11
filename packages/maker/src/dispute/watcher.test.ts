import { describe, it, expect, vi } from "vitest";
import { encodeEventTopics, encodeAbiParameters, parseAbiItem } from "viem";
import { DisputeWatcher } from "./watcher.js";
import type { FillSubmittedEvent } from "../chain/watcher.js";
import type { Order } from "@gauloi/common";

// --- helpers ---

const MAKER = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" as `0x${string}`;
const OTHER_MAKER = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" as `0x${string}`;
const DISPUTES = "0xcccccccccccccccccccccccccccccccccccccccc" as `0x${string}`;
const OUTPUT_TOKEN = "0x3333333333333333333333333333333333333333" as `0x${string}`;
const DEST_ADDR = "0x1111111111111111111111111111111111111111" as `0x${string}`;

const TRANSFER_EVENT = parseAbiItem(
  "event Transfer(address indexed from, address indexed to, uint256 value)",
);

function makeOrder(overrides: Partial<Order> = {}): Order {
  return {
    taker: "0x1111111111111111111111111111111111111111",
    inputToken: "0x2222222222222222222222222222222222222222",
    inputAmount: 1_000_000n,
    outputToken: OUTPUT_TOKEN,
    minOutputAmount: 990_000n,
    destinationChainId: 421614n,
    destinationAddress: DEST_ADDR,
    expiry: BigInt(Math.floor(Date.now() / 1000) + 3600),
    nonce: 1n,
    ...overrides,
  };
}

function makeFillEvent(overrides: Partial<FillSubmittedEvent> = {}): FillSubmittedEvent {
  return {
    intentId: "0xINTENT1" as `0x${string}`,
    maker: OTHER_MAKER,
    fillTxHash: "0xFILL_TX" as `0x${string}`,
    disputeWindowEnd: BigInt(Math.floor(Date.now() / 1000) + 3600),
    ...overrides,
  };
}

/** Build a mock ERC20 Transfer log with proper ABI encoding */
function makeTransferLog(
  tokenAddress: `0x${string}`,
  from: `0x${string}`,
  to: `0x${string}`,
  value: bigint,
) {
  const topics = encodeEventTopics({
    abi: [TRANSFER_EVENT],
    eventName: "Transfer",
    args: { from, to },
  });

  const data = encodeAbiParameters(
    [{ type: "uint256" }],
    [value],
  );

  return {
    address: tokenAddress,
    topics,
    data,
    blockNumber: 100n,
    transactionHash: "0xFILL_TX" as `0x${string}`,
    logIndex: 0,
    blockHash: "0x" as `0x${string}`,
    transactionIndex: 0,
    removed: false,
  };
}

// --- tests ---

describe("DisputeWatcher.verifyFill", () => {
  it("returns true for own fills (skips verification)", async () => {
    const destPublicClient = { getTransactionReceipt: vi.fn() } as any;
    const sourceWalletClient = {} as any;

    const watcher = new DisputeWatcher(destPublicClient, sourceWalletClient, DISPUTES, MAKER);

    const result = await watcher.verifyFill(
      makeFillEvent({ maker: MAKER }),
      makeOrder(),
    );

    expect(result).toBe(true);
    expect(destPublicClient.getTransactionReceipt).not.toHaveBeenCalled();
  });

  it("returns false when no order data is provided", async () => {
    const destPublicClient = { getTransactionReceipt: vi.fn() } as any;
    const sourceWalletClient = {} as any;

    const watcher = new DisputeWatcher(destPublicClient, sourceWalletClient, DISPUTES, MAKER);

    const result = await watcher.verifyFill(makeFillEvent());

    expect(result).toBe(false);
  });

  it("returns true when receipt contains valid Transfer log", async () => {
    const transferLog = makeTransferLog(
      OUTPUT_TOKEN,
      OTHER_MAKER,
      DEST_ADDR,
      990_000n,
    );

    const destPublicClient = {
      getTransactionReceipt: vi.fn().mockResolvedValue({
        status: "success",
        logs: [transferLog],
      }),
    } as any;
    const sourceWalletClient = {} as any;

    const watcher = new DisputeWatcher(destPublicClient, sourceWalletClient, DISPUTES, MAKER);

    const result = await watcher.verifyFill(makeFillEvent(), makeOrder());

    expect(result).toBe(true);
  });

  it("returns true when transfer amount exceeds minOutputAmount", async () => {
    const transferLog = makeTransferLog(
      OUTPUT_TOKEN,
      OTHER_MAKER,
      DEST_ADDR,
      2_000_000n, // More than min
    );

    const destPublicClient = {
      getTransactionReceipt: vi.fn().mockResolvedValue({
        status: "success",
        logs: [transferLog],
      }),
    } as any;
    const sourceWalletClient = {} as any;

    const watcher = new DisputeWatcher(destPublicClient, sourceWalletClient, DISPUTES, MAKER);

    const result = await watcher.verifyFill(makeFillEvent(), makeOrder());

    expect(result).toBe(true);
  });

  it("returns false when transfer is to wrong recipient", async () => {
    const wrongRecipient = "0xdddddddddddddddddddddddddddddddddddddddd" as `0x${string}`;
    const transferLog = makeTransferLog(
      OUTPUT_TOKEN,
      OTHER_MAKER,
      wrongRecipient,
      990_000n,
    );

    const destPublicClient = {
      getTransactionReceipt: vi.fn().mockResolvedValue({
        status: "success",
        logs: [transferLog],
      }),
    } as any;
    const sourceWalletClient = {} as any;

    const watcher = new DisputeWatcher(destPublicClient, sourceWalletClient, DISPUTES, MAKER);

    const result = await watcher.verifyFill(makeFillEvent(), makeOrder());

    expect(result).toBe(false);
  });

  it("returns false when transfer amount is below minOutputAmount", async () => {
    const transferLog = makeTransferLog(
      OUTPUT_TOKEN,
      OTHER_MAKER,
      DEST_ADDR,
      500_000n, // Below min
    );

    const destPublicClient = {
      getTransactionReceipt: vi.fn().mockResolvedValue({
        status: "success",
        logs: [transferLog],
      }),
    } as any;
    const sourceWalletClient = {} as any;

    const watcher = new DisputeWatcher(destPublicClient, sourceWalletClient, DISPUTES, MAKER);

    const result = await watcher.verifyFill(makeFillEvent(), makeOrder());

    expect(result).toBe(false);
  });

  it("returns false when transfer is on wrong token contract", async () => {
    const wrongToken = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" as `0x${string}`;
    const transferLog = makeTransferLog(
      wrongToken,
      OTHER_MAKER,
      DEST_ADDR,
      990_000n,
    );

    const destPublicClient = {
      getTransactionReceipt: vi.fn().mockResolvedValue({
        status: "success",
        logs: [transferLog],
      }),
    } as any;
    const sourceWalletClient = {} as any;

    const watcher = new DisputeWatcher(destPublicClient, sourceWalletClient, DISPUTES, MAKER);

    const result = await watcher.verifyFill(makeFillEvent(), makeOrder());

    expect(result).toBe(false);
  });

  it("returns false when transaction reverted", async () => {
    const destPublicClient = {
      getTransactionReceipt: vi.fn().mockResolvedValue({
        status: "reverted",
        logs: [],
      }),
    } as any;
    const sourceWalletClient = {} as any;

    const watcher = new DisputeWatcher(destPublicClient, sourceWalletClient, DISPUTES, MAKER);

    const result = await watcher.verifyFill(makeFillEvent(), makeOrder());

    expect(result).toBe(false);
  });

  it("returns false when receipt has no logs", async () => {
    const destPublicClient = {
      getTransactionReceipt: vi.fn().mockResolvedValue({
        status: "success",
        logs: [],
      }),
    } as any;
    const sourceWalletClient = {} as any;

    const watcher = new DisputeWatcher(destPublicClient, sourceWalletClient, DISPUTES, MAKER);

    const result = await watcher.verifyFill(makeFillEvent(), makeOrder());

    expect(result).toBe(false);
  });

  it("returns false when transaction receipt is not found", async () => {
    const err = new Error("Transaction receipt not found");
    (err as any).name = "TransactionReceiptNotFoundError";
    const destPublicClient = {
      getTransactionReceipt: vi.fn().mockRejectedValue(err),
    } as any;
    const sourceWalletClient = {} as any;

    const watcher = new DisputeWatcher(destPublicClient, sourceWalletClient, DISPUTES, MAKER);

    const result = await watcher.verifyFill(makeFillEvent(), makeOrder());

    expect(result).toBe(false);
  });

  it("re-throws transient RPC errors", async () => {
    const destPublicClient = {
      getTransactionReceipt: vi.fn().mockRejectedValue(new Error("request timeout")),
    } as any;
    const sourceWalletClient = {} as any;

    const watcher = new DisputeWatcher(destPublicClient, sourceWalletClient, DISPUTES, MAKER);

    await expect(
      watcher.verifyFill(makeFillEvent(), makeOrder()),
    ).rejects.toThrow("request timeout");
  });

  it("handles case-insensitive address comparison", async () => {
    const transferLog = makeTransferLog(
      OUTPUT_TOKEN,
      OTHER_MAKER,
      DEST_ADDR,
      990_000n,
    );
    // Override address to uppercase to test case-insensitivity
    transferLog.address = OUTPUT_TOKEN.toUpperCase() as `0x${string}`;

    const destPublicClient = {
      getTransactionReceipt: vi.fn().mockResolvedValue({
        status: "success",
        logs: [transferLog],
      }),
    } as any;
    const sourceWalletClient = {} as any;

    const watcher = new DisputeWatcher(destPublicClient, sourceWalletClient, DISPUTES, MAKER);

    const result = await watcher.verifyFill(makeFillEvent(), makeOrder());

    expect(result).toBe(true);
  });
});
