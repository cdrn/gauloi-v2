import { describe, it, expect, vi } from "vitest";
import { encodeEventTopics, encodeAbiParameters, parseAbiItem } from "viem";
import { verifyFillOnDestination } from "./verify-fill.js";
import type { Order } from "@gauloi/common";

// --- helpers ---

const OUTPUT_TOKEN = "0x3333333333333333333333333333333333333333" as `0x${string}`;
const DEST_ADDR = "0x1111111111111111111111111111111111111111" as `0x${string}`;
const MAKER = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" as `0x${string}`;

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

  const data = encodeAbiParameters([{ type: "uint256" }], [value]);

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

describe("verifyFillOnDestination", () => {
  it("returns true when receipt contains valid Transfer log", async () => {
    const transferLog = makeTransferLog(OUTPUT_TOKEN, MAKER, DEST_ADDR, 990_000n);

    const client = {
      getTransactionReceipt: vi.fn().mockResolvedValue({
        status: "success",
        logs: [transferLog],
      }),
    } as any;

    const result = await verifyFillOnDestination(client, "0xFILL_TX", makeOrder());
    expect(result).toBe(true);
  });

  it("returns false when transfer is to wrong recipient", async () => {
    const wrongRecipient = "0xDDdDddDdDdddDDddDDddDDDDdDdDDdDDdDDDDDDd" as `0x${string}`;
    const transferLog = makeTransferLog(OUTPUT_TOKEN, MAKER, wrongRecipient, 990_000n);

    const client = {
      getTransactionReceipt: vi.fn().mockResolvedValue({
        status: "success",
        logs: [transferLog],
      }),
    } as any;

    const result = await verifyFillOnDestination(client, "0xFILL_TX", makeOrder());
    expect(result).toBe(false);
  });

  it("returns false when transfer amount is insufficient", async () => {
    const transferLog = makeTransferLog(OUTPUT_TOKEN, MAKER, DEST_ADDR, 500_000n);

    const client = {
      getTransactionReceipt: vi.fn().mockResolvedValue({
        status: "success",
        logs: [transferLog],
      }),
    } as any;

    const result = await verifyFillOnDestination(client, "0xFILL_TX", makeOrder());
    expect(result).toBe(false);
  });

  it("returns false when transfer is on wrong token", async () => {
    const wrongToken = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" as `0x${string}`;
    const transferLog = makeTransferLog(wrongToken, MAKER, DEST_ADDR, 990_000n);

    const client = {
      getTransactionReceipt: vi.fn().mockResolvedValue({
        status: "success",
        logs: [transferLog],
      }),
    } as any;

    const result = await verifyFillOnDestination(client, "0xFILL_TX", makeOrder());
    expect(result).toBe(false);
  });

  it("returns false when transaction reverted", async () => {
    const client = {
      getTransactionReceipt: vi.fn().mockResolvedValue({
        status: "reverted",
        logs: [],
      }),
    } as any;

    const result = await verifyFillOnDestination(client, "0xFILL_TX", makeOrder());
    expect(result).toBe(false);
  });

  it("returns false when receipt has no logs", async () => {
    const client = {
      getTransactionReceipt: vi.fn().mockResolvedValue({
        status: "success",
        logs: [],
      }),
    } as any;

    const result = await verifyFillOnDestination(client, "0xFILL_TX", makeOrder());
    expect(result).toBe(false);
  });

  it("returns false when getTransactionReceipt throws", async () => {
    const client = {
      getTransactionReceipt: vi.fn().mockRejectedValue(new Error("not found")),
    } as any;

    const result = await verifyFillOnDestination(client, "0xFILL_TX", makeOrder());
    expect(result).toBe(false);
  });
});
