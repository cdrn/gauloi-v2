import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { WebSocketServer, WebSocket } from "ws";
import { createServer, type Server } from "http";
import { Relay } from "./relay.js";
import { MessageType } from "./types.js";

// Mock verifyQuoteSignature to avoid needing real EIP-712 signatures in unit tests
vi.mock("@gauloi/common", () => ({
  verifyQuoteSignature: vi.fn().mockResolvedValue(true),
}));

// --- helpers ---

function freePort(): Promise<number> {
  return new Promise((resolve) => {
    const srv = createServer();
    srv.listen(0, () => {
      const port = (srv.address() as any).port;
      srv.close(() => resolve(port));
    });
  });
}

function connect(port: number): Promise<WebSocket> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}`);
    ws.on("open", () => resolve(ws));
    ws.on("error", reject);
  });
}

function nextMessage(ws: WebSocket): Promise<any> {
  return new Promise((resolve) => {
    ws.once("message", (raw) => resolve(JSON.parse(raw.toString())));
  });
}

/** Collect all messages arriving within `ms` milliseconds. */
function collectMessages(ws: WebSocket, ms = 100): Promise<any[]> {
  return new Promise((resolve) => {
    const msgs: any[] = [];
    const handler = (raw: any) => msgs.push(JSON.parse(raw.toString()));
    ws.on("message", handler);
    setTimeout(() => {
      ws.off("message", handler);
      resolve(msgs);
    }, ms);
  });
}

function makeIntentBroadcast(overrides: Record<string, any> = {}) {
  return {
    type: MessageType.IntentBroadcast,
    data: {
      intentId: "0xabc123",
      taker: "0xTAKER",
      inputToken: "0xUSDC",
      inputAmount: "1000000",
      outputToken: "0xUSDC_ARB",
      destinationChainId: 42161,
      destinationAddress: "0xTAKER",
      minOutputAmount: "990000",
      expiry: Math.floor(Date.now() / 1000) + 3600,
      nonce: "12345",
      takerSignature: "0xSIG_TAKER",
      sourceChainId: 1,
      ...overrides,
    },
  };
}

function makeMakerQuote(intentId: string, maker: string) {
  return {
    type: MessageType.MakerQuote,
    data: {
      intentId,
      maker,
      outputAmount: "995000",
      estimatedFillTime: 30,
      expiry: Math.floor(Date.now() / 1000) + 300,
      signature: "0xQUOTE_SIG",
    },
  };
}

// --- test suite ---

let httpServer: Server;
let wss: WebSocketServer;
let relay: Relay;
let port: number;

beforeEach(async () => {
  port = await freePort();
  httpServer = createServer();
  wss = new WebSocketServer({ server: httpServer });
  relay = new Relay();
  relay.attach(wss);
  await new Promise<void>((r) => httpServer.listen(port, r));
});

afterEach(async () => {
  relay.stop();
  wss.close();
  await new Promise<void>((r) => httpServer.close(() => r()));
});

// -------------------------------------------------------
// NewIntent broadcast: must NOT include takerSignature or nonce
// -------------------------------------------------------

describe("NewIntent broadcast", () => {
  it("does not include takerSignature or nonce", async () => {
    const maker = await connect(port);
    maker.send(JSON.stringify({
      type: MessageType.MakerSubscribe,
      data: { address: "0xMAKER" },
    }));

    // Small delay so subscribe is processed before broadcast
    await new Promise((r) => setTimeout(r, 50));

    const pending = nextMessage(maker);

    const taker = await connect(port);
    taker.send(JSON.stringify(makeIntentBroadcast()));

    const msg = await pending;

    expect(msg.type).toBe(MessageType.NewIntent);
    expect(msg.data.takerSignature).toBeUndefined();
    expect(msg.data.nonce).toBeUndefined();

    // Should still have the non-sensitive fields
    expect(msg.data.intentId).toBe("0xabc123");
    expect(msg.data.taker).toBe("0xTAKER");
    expect(msg.data.inputToken).toBe("0xUSDC");
    expect(msg.data.inputAmount).toBe("1000000");
    expect(msg.data.expiry).toBeDefined();
    expect(msg.data.sourceChainId).toBe(1);

    maker.close();
    taker.close();
  });

  it("broadcasts to all makers", async () => {
    const maker1 = await connect(port);
    const maker2 = await connect(port);
    maker1.send(JSON.stringify({ type: MessageType.MakerSubscribe, data: { address: "0xM1" } }));
    maker2.send(JSON.stringify({ type: MessageType.MakerSubscribe, data: { address: "0xM2" } }));
    await new Promise((r) => setTimeout(r, 50));

    const p1 = nextMessage(maker1);
    const p2 = nextMessage(maker2);

    const taker = await connect(port);
    taker.send(JSON.stringify(makeIntentBroadcast()));

    const [msg1, msg2] = await Promise.all([p1, p2]);
    expect(msg1.type).toBe(MessageType.NewIntent);
    expect(msg2.type).toBe(MessageType.NewIntent);

    maker1.close();
    maker2.close();
    taker.close();
  });

  it("does not broadcast to non-maker clients", async () => {
    const spectator = await connect(port);
    // Don't subscribe as maker
    await new Promise((r) => setTimeout(r, 50));

    const msgs = collectMessages(spectator, 200);

    const taker = await connect(port);
    taker.send(JSON.stringify(makeIntentBroadcast()));

    const received = await msgs;
    expect(received).toHaveLength(0);

    spectator.close();
    taker.close();
  });
});

// -------------------------------------------------------
// QuoteAccepted: must include expiry, nonce, takerSignature
// and only go to the selected maker
// -------------------------------------------------------

describe("QuoteAccepted message", () => {
  it("includes expiry, nonce, and takerSignature", async () => {
    // 1. Connect taker + two makers
    const taker = await connect(port);
    const makerA = await connect(port);
    const makerB = await connect(port);
    makerA.send(JSON.stringify({ type: MessageType.MakerSubscribe, data: { address: "0xMAKER_A" } }));
    makerB.send(JSON.stringify({ type: MessageType.MakerSubscribe, data: { address: "0xMAKER_B" } }));
    await new Promise((r) => setTimeout(r, 50));

    // Drain NewIntent messages from makers
    const drainA = collectMessages(makerA, 200);
    const drainB = collectMessages(makerB, 200);

    // 2. Taker broadcasts intent
    const broadcast = makeIntentBroadcast({
      expiry: 1700000000,
      nonce: "99999",
      takerSignature: "0xREAL_SIG",
    });
    taker.send(JSON.stringify(broadcast));
    await Promise.all([drainA, drainB]);

    // 3. Maker A submits a quote
    const quoteForTaker = nextMessage(taker);
    makerA.send(JSON.stringify(makeMakerQuote("0xabc123", "0xMAKER_A")));
    await quoteForTaker; // wait for relay to forward quote to taker

    // 4. Taker selects maker A — listen for QuoteAccepted on maker A
    const accepted = nextMessage(makerA);
    const bMessages = collectMessages(makerB, 200);

    taker.send(JSON.stringify({
      type: MessageType.QuoteSelect,
      data: { intentId: "0xabc123", maker: "0xMAKER_A" },
    }));

    const msg = await accepted;

    expect(msg.type).toBe(MessageType.QuoteAccepted);
    expect(msg.data.expiry).toBe(1700000000);
    expect(msg.data.nonce).toBe("99999");
    expect(msg.data.takerSignature).toBe("0xREAL_SIG");
    expect(msg.data.intentId).toBe("0xabc123");
    expect(msg.data.taker).toBe("0xTAKER");
    expect(msg.data.inputToken).toBe("0xUSDC");
    expect(msg.data.inputAmount).toBe("1000000");
    expect(msg.data.outputToken).toBe("0xUSDC_ARB");
    expect(msg.data.minOutputAmount).toBe("990000");
    expect(msg.data.destinationChainId).toBe(42161);
    expect(msg.data.destinationAddress).toBe("0xTAKER");
    expect(msg.data.sourceChainId).toBe(1);

    // 5. Maker B must NOT receive QuoteAccepted
    const bReceived = await bMessages;
    const acceptedMsgs = bReceived.filter((m) => m.type === MessageType.QuoteAccepted);
    expect(acceptedMsgs).toHaveLength(0);

    taker.close();
    makerA.close();
    makerB.close();
  });

  it("only sends to the selected maker, not others", async () => {
    const taker = await connect(port);
    const makerA = await connect(port);
    const makerB = await connect(port);
    makerA.send(JSON.stringify({ type: MessageType.MakerSubscribe, data: { address: "0xA" } }));
    makerB.send(JSON.stringify({ type: MessageType.MakerSubscribe, data: { address: "0xB" } }));
    await new Promise((r) => setTimeout(r, 50));

    // Drain NewIntent
    const drainA = collectMessages(makerA, 150);
    const drainB = collectMessages(makerB, 150);
    taker.send(JSON.stringify(makeIntentBroadcast()));
    await Promise.all([drainA, drainB]);

    // Both quote
    const q1 = nextMessage(taker);
    makerA.send(JSON.stringify(makeMakerQuote("0xabc123", "0xA")));
    await q1;
    const q2 = nextMessage(taker);
    makerB.send(JSON.stringify(makeMakerQuote("0xabc123", "0xB")));
    await q2;

    // Select maker B
    const acceptedB = nextMessage(makerB);
    const msgsA = collectMessages(makerA, 200);

    taker.send(JSON.stringify({
      type: MessageType.QuoteSelect,
      data: { intentId: "0xabc123", maker: "0xB" },
    }));

    const msg = await acceptedB;
    expect(msg.type).toBe(MessageType.QuoteAccepted);
    expect(msg.data.takerSignature).toBe("0xSIG_TAKER");

    const aReceived = await msgsA;
    expect(aReceived.filter((m) => m.type === MessageType.QuoteAccepted)).toHaveLength(0);

    taker.close();
    makerA.close();
    makerB.close();
  });
});

// -------------------------------------------------------
// QuoteSelect error cases
// -------------------------------------------------------

describe("QuoteSelect errors", () => {
  it("rejects selection for unknown intent", async () => {
    const taker = await connect(port);
    const errMsg = nextMessage(taker);

    taker.send(JSON.stringify({
      type: MessageType.QuoteSelect,
      data: { intentId: "0xNONEXISTENT", maker: "0xA" },
    }));

    const msg = await errMsg;
    expect(msg.type).toBe(MessageType.Error);

    taker.close();
  });

  it("rejects double selection", async () => {
    const taker = await connect(port);
    const maker = await connect(port);
    maker.send(JSON.stringify({ type: MessageType.MakerSubscribe, data: { address: "0xM" } }));
    await new Promise((r) => setTimeout(r, 50));

    // Drain NewIntent
    const drain = collectMessages(maker, 150);
    taker.send(JSON.stringify(makeIntentBroadcast()));
    await drain;

    // Quote + select
    const q = nextMessage(taker);
    maker.send(JSON.stringify(makeMakerQuote("0xabc123", "0xM")));
    await q;

    const accepted = nextMessage(maker);
    taker.send(JSON.stringify({
      type: MessageType.QuoteSelect,
      data: { intentId: "0xabc123", maker: "0xM" },
    }));
    await accepted;

    // Try to select again
    const errMsg = nextMessage(taker);
    taker.send(JSON.stringify({
      type: MessageType.QuoteSelect,
      data: { intentId: "0xabc123", maker: "0xM" },
    }));

    const msg = await errMsg;
    expect(msg.type).toBe(MessageType.Error);

    taker.close();
    maker.close();
  });
});

// -------------------------------------------------------
// Store: intent data is preserved correctly
// -------------------------------------------------------

describe("store integrity", () => {
  it("stores full intent data including signature and nonce", async () => {
    const taker = await connect(port);
    taker.send(JSON.stringify(makeIntentBroadcast({
      nonce: "777",
      takerSignature: "0xKEPT",
      expiry: 9999999999,
    })));

    // Wait for processing
    await new Promise((r) => setTimeout(r, 50));

    const stored = relay.getStore().getIntent("0xabc123");
    expect(stored).toBeDefined();
    expect(stored!.intent.nonce).toBe("777");
    expect(stored!.intent.takerSignature).toBe("0xKEPT");
    expect(stored!.intent.expiry).toBe(9999999999);

    taker.close();
  });
});
