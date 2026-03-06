import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { MakerBot, type BotConfig } from "./bot.js";
import type { Order } from "@gauloi/common";

// Mock all dependencies
vi.mock("ws", () => {
  const handlers = new Map<string, Function[]>();
  const MockWebSocket = vi.fn().mockImplementation(() => ({
    on: vi.fn((event: string, handler: Function) => {
      if (!handlers.has(event)) handlers.set(event, []);
      handlers.get(event)!.push(handler);
      // Auto-trigger "open" immediately
      if (event === "open") setTimeout(() => handler(), 0);
    }),
    send: vi.fn(),
    close: vi.fn(),
    _handlers: handlers,
    _emit: (event: string, ...args: any[]) => {
      for (const h of handlers.get(event) ?? []) h(...args);
    },
  }));
  return { default: MockWebSocket };
});

vi.mock("@gauloi/common", async () => {
  const actual = await vi.importActual("@gauloi/common");
  return {
    ...actual,
    signQuote: vi.fn().mockResolvedValue("0xMOCK_SIG"),
  };
});

// --- helpers ---

function makeOrder(overrides: Partial<Order> = {}): Order {
  return {
    taker: "0x1111111111111111111111111111111111111111",
    inputToken: "0x2222222222222222222222222222222222222222",
    inputAmount: 1_000_000n,
    outputToken: "0x3333333333333333333333333333333333333333",
    minOutputAmount: 990_000n,
    destinationChainId: 421614n,
    destinationAddress: "0x1111111111111111111111111111111111111111",
    expiry: BigInt(Math.floor(Date.now() / 1000) + 3600),
    nonce: 1n,
    ...overrides,
  };
}

function createMockConfig(): BotConfig {
  const sourcePublicClient = {
    readContract: vi.fn().mockResolvedValue(10_000_000n), // availableCapacity
    waitForTransactionReceipt: vi.fn().mockResolvedValue({}),
    watchContractEvent: vi.fn().mockReturnValue(() => {}),
  } as any;

  const sourceWalletClient = {
    writeContract: vi.fn().mockResolvedValue("0xSOURCE_TX"),
    account: { address: "0xMAKER" },
  } as any;

  const destPublicClient = {
    getTransaction: vi.fn().mockResolvedValue({ hash: "0xFILL" }),
    waitForTransactionReceipt: vi.fn().mockResolvedValue({}),
  } as any;

  const destWalletClient = {
    writeContract: vi.fn().mockResolvedValue("0xDEST_TX"),
  } as any;

  return {
    makerAddress: "0xMAKER000000000000000000000000000000000000" as `0x${string}`,
    relayUrl: "ws://localhost:9999",
    sourceChain: {
      chainId: 11155111,
      name: "Sepolia",
      escrowAddress: "0xESCROW0000000000000000000000000000000000" as `0x${string}`,
      stakingAddress: "0xSTAKING000000000000000000000000000000000" as `0x${string}`,
      disputesAddress: "0xDISPUTE000000000000000000000000000000000" as `0x${string}`,
      usdcAddress: "0xUSDC00000000000000000000000000000000000000" as `0x${string}`,
      settlementWindow: 3600,
    },
    destChain: {
      chainId: 421614,
      name: "Arb Sepolia",
      escrowAddress: "0xESCROW0000000000000000000000000000000001" as `0x${string}`,
      stakingAddress: "0xSTAKING000000000000000000000000000000001" as `0x${string}`,
      disputesAddress: "0xDISPUTE000000000000000000000000000000001" as `0x${string}`,
      usdcAddress: "0xUSDC00000000000000000000000000000000000001" as `0x${string}`,
      settlementWindow: 3600,
    },
    sourcePublicClient,
    sourceWalletClient,
    destPublicClient,
    destWalletClient,
    settleIntervalMs: 999_999, // Very long — we'll trigger manually
  };
}

// --- tests ---

describe("MakerBot order cache for disputes", () => {
  let config: BotConfig;
  let bot: MakerBot;
  let fillCallback: Function;

  beforeEach(async () => {
    config = createMockConfig();

    // Capture the fill watcher callback when watchContractEvent is called
    (config.sourcePublicClient.watchContractEvent as any).mockImplementation(
      ({ onLogs }: any) => {
        fillCallback = onLogs;
        return () => {};
      },
    );

    // Mock fetch for backfill (relay /intents endpoint)
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({
      ok: true,
      json: async () => [],
    }));

    bot = new MakerBot(config);
    await bot.start();
    // Wait for WebSocket open + backfill
    await new Promise((r) => setTimeout(r, 50));
  });

  afterEach(() => {
    bot.stop();
    vi.unstubAllGlobals();
  });

  it("caches order on quote accepted and passes it to dispute", async () => {
    const intentId = "0xINTENT_CACHE_TEST";

    // Simulate a quote_accepted relay message
    const quoteAcceptedData = {
      intentId,
      taker: "0x1111111111111111111111111111111111111111",
      inputToken: "0x2222222222222222222222222222222222222222",
      inputAmount: "1000000",
      outputToken: "0x3333333333333333333333333333333333333333",
      minOutputAmount: "990000",
      destinationChainId: 421614,
      destinationAddress: "0x1111111111111111111111111111111111111111",
      expiry: Math.floor(Date.now() / 1000) + 3600,
      nonce: "1",
      takerSignature: "0xTAKER_SIG",
      sourceChainId: 11155111,
    };

    // Process quote_accepted — this should cache the order
    // Access handleRelayMessage via simulating a relay message
    const ws = (bot as any).ws;
    ws._emit("message", JSON.stringify({
      type: "quote_accepted",
      data: quoteAcceptedData,
    }));

    // Wait for async processing
    await new Promise((r) => setTimeout(r, 100));

    // Verify order was cached
    const cachedOrder = (bot as any).orderCache.get(intentId);
    expect(cachedOrder).toBeDefined();
    expect(cachedOrder.taker).toBe("0x1111111111111111111111111111111111111111");
    expect(cachedOrder.inputAmount).toBe(1_000_000n);

    // Now simulate a fill event from a different maker that fails verification
    // Mock destPublicClient.getTransaction to throw (fill tx not found)
    (config.destPublicClient.getTransaction as any).mockRejectedValueOnce(
      new Error("tx not found"),
    );

    // Spy on the dispute contract call
    const disputeSpy = config.sourceWalletClient.writeContract as any;
    disputeSpy.mockClear();

    // Trigger fill event for same intent from a different maker
    fillCallback([
      {
        args: {
          intentId,
          maker: "0xOTHER_MAKER_0000000000000000000000000000",
          fillTxHash: "0xSUSPECT_TX",
          disputeWindowEnd: BigInt(Math.floor(Date.now() / 1000) + 3600),
        },
      },
    ]);

    // Wait for async dispute processing
    await new Promise((r) => setTimeout(r, 200));

    // The dispute watcher should have called writeContract with the cached order
    expect(disputeSpy).toHaveBeenCalledWith(
      expect.objectContaining({
        functionName: "dispute",
        args: [cachedOrder],
      }),
    );
  });

  it("cleans up order cache on fill failure", async () => {
    const intentId = "0xFAIL_INTENT";

    // Make executeOrder throw to simulate failure
    (config.sourceWalletClient.writeContract as any).mockRejectedValueOnce(
      new Error("execution reverted"),
    );

    const ws = (bot as any).ws;
    ws._emit("message", JSON.stringify({
      type: "quote_accepted",
      data: {
        intentId,
        taker: "0x1111111111111111111111111111111111111111",
        inputToken: "0x2222222222222222222222222222222222222222",
        inputAmount: "1000000",
        outputToken: "0x3333333333333333333333333333333333333333",
        minOutputAmount: "990000",
        destinationChainId: 421614,
        destinationAddress: "0x1111111111111111111111111111111111111111",
        expiry: Math.floor(Date.now() / 1000) + 3600,
        nonce: "2",
        takerSignature: "0xSIG",
        sourceChainId: 11155111,
      },
    }));

    await new Promise((r) => setTimeout(r, 100));

    // Order cache should have been cleaned up on failure
    expect((bot as any).orderCache.get(intentId)).toBeUndefined();
  });
});
