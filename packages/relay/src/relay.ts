import { WebSocketServer, WebSocket } from "ws";
import { verifyQuoteSignature } from "@gauloi/common";
import { MemoryStore } from "./store/memory.js";
import {
  MessageType,
  type RelayMessage,
  type IntentBroadcastMessage,
  type MakerQuoteMessage,
  type MakerSubscribeMessage,
  type QuoteSelectMessage,
} from "./types.js";

interface ConnectedClient {
  ws: WebSocket;
  role: "maker" | "taker" | "unknown";
  address?: string;
  chains?: number[];
}

export class Relay {
  private store: MemoryStore;
  private clients = new Set<ConnectedClient>();
  private pruneInterval: ReturnType<typeof setInterval> | null = null;

  constructor(store?: MemoryStore) {
    this.store = store ?? new MemoryStore();
  }

  attach(wss: WebSocketServer): void {
    wss.on("connection", (ws) => {
      const client: ConnectedClient = { ws, role: "unknown" };
      this.clients.add(client);

      ws.on("message", (raw) => {
        try {
          const msg: RelayMessage = JSON.parse(raw.toString());
          this.handleMessage(client, msg);
        } catch {
          this.sendError(ws, "Invalid message format");
        }
      });

      ws.on("close", () => {
        this.clients.delete(client);
      });
    });

    // Prune expired intents every 60s
    this.pruneInterval = setInterval(() => {
      this.store.pruneExpired();
    }, 60_000);
  }

  stop(): void {
    if (this.pruneInterval) {
      clearInterval(this.pruneInterval);
      this.pruneInterval = null;
    }
  }

  private handleMessage(client: ConnectedClient, msg: RelayMessage): void {
    switch (msg.type) {
      case MessageType.MakerSubscribe:
        client.role = "maker";
        client.address = (msg as MakerSubscribeMessage).data?.address;
        client.chains = (msg as MakerSubscribeMessage).data?.chains;
        break;

      case MessageType.IntentBroadcast:
        this.handleIntentBroadcast(client, msg as IntentBroadcastMessage);
        break;

      case MessageType.MakerQuote:
        this.handleMakerQuote(client, msg as MakerQuoteMessage);
        break;

      case MessageType.QuoteSelect:
        this.handleQuoteSelect(client, msg as QuoteSelectMessage);
        break;

      default:
        this.sendError(client.ws, `Unknown message type: ${(msg as any).type}`);
    }
  }

  private handleIntentBroadcast(
    client: ConnectedClient,
    msg: IntentBroadcastMessage,
  ): void {
    client.role = "taker";
    client.address = msg.data.taker;

    this.store.addIntent(msg.data);

    // Broadcast to all connected makers (strip signature — only sent to selected maker)
    const { takerSignature: _sig, nonce: _nonce, ...intentData } = msg.data;
    const outMsg = JSON.stringify({
      type: MessageType.NewIntent,
      data: intentData,
    });

    for (const c of this.clients) {
      if (c.role === "maker" && c.ws.readyState === WebSocket.OPEN) {
        c.ws.send(outMsg);
      }
    }
  }

  private async handleMakerQuote(
    client: ConnectedClient,
    msg: MakerQuoteMessage,
  ): Promise<void> {
    // Verify EIP-712 signature
    const valid = await verifyQuoteSignature(
      {
        intentId: msg.data.intentId as `0x${string}`,
        maker: msg.data.maker as `0x${string}`,
        outputAmount: BigInt(msg.data.outputAmount),
        estimatedFillTime: msg.data.estimatedFillTime,
        expiry: msg.data.expiry,
      },
      msg.data.signature as `0x${string}`,
    );

    if (!valid) {
      this.sendError(client.ws, "Invalid quote signature");
      return;
    }

    const added = this.store.addQuote(msg.data.intentId, msg.data);
    if (!added) {
      this.sendError(client.ws, "Cannot add quote: intent not found or already selected");
      return;
    }

    // Forward quote to the taker who created this intent
    const stored = this.store.getIntent(msg.data.intentId);
    if (!stored) return;

    const outMsg = JSON.stringify({
      type: MessageType.QuoteReceived,
      data: msg.data,
    });

    for (const c of this.clients) {
      if (
        c.role === "taker" &&
        c.address === stored.intent.taker &&
        c.ws.readyState === WebSocket.OPEN
      ) {
        c.ws.send(outMsg);
      }
    }
  }

  private handleQuoteSelect(
    client: ConnectedClient,
    msg: QuoteSelectMessage,
  ): void {
    const selected = this.store.selectQuote(msg.data.intentId, msg.data.maker);
    if (!selected) {
      this.sendError(client.ws, "Cannot select quote: not found or already selected");
      return;
    }

    const stored = this.store.getIntent(msg.data.intentId);
    if (!stored) return;

    // Notify the winning maker with order data + taker signature
    const outMsg = JSON.stringify({
      type: MessageType.QuoteAccepted,
      data: {
        intentId: stored.intent.intentId,
        taker: stored.intent.taker,
        inputToken: stored.intent.inputToken,
        inputAmount: stored.intent.inputAmount,
        outputToken: stored.intent.outputToken,
        destinationChainId: stored.intent.destinationChainId,
        destinationAddress: stored.intent.destinationAddress,
        minOutputAmount: stored.intent.minOutputAmount,
        expiry: stored.intent.expiry,
        nonce: stored.intent.nonce,
        takerSignature: stored.intent.takerSignature,
        sourceChainId: stored.intent.sourceChainId,
      },
    });

    for (const c of this.clients) {
      if (
        c.role === "maker" &&
        c.address === msg.data.maker &&
        c.ws.readyState === WebSocket.OPEN
      ) {
        c.ws.send(outMsg);
      }
    }
  }

  private sendError(ws: WebSocket, message: string): void {
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(
        JSON.stringify({
          type: MessageType.Error,
          data: { message },
        }),
      );
    }
  }

  // Expose store for HTTP endpoints
  getStore(): MemoryStore {
    return this.store;
  }

  getStats(): {
    makers: Record<string, { count: number; addresses: string[] }>;
    intents: { total: number; open: number; filled: number; volume: string };
  } {
    const makers: Record<string, { count: number; addresses: string[] }> = {};

    for (const c of this.clients) {
      if (c.role === "maker" && c.address && c.ws.readyState === WebSocket.OPEN) {
        const chainIds = c.chains ?? [];
        for (const chainId of chainIds) {
          const key = String(chainId);
          if (!makers[key]) {
            makers[key] = { count: 0, addresses: [] };
          }
          if (!makers[key].addresses.includes(c.address)) {
            makers[key].addresses.push(c.address);
            makers[key].count++;
          }
        }
        // If no chains reported, still count the maker under "unknown"
        if (chainIds.length === 0) {
          if (!makers["0"]) {
            makers["0"] = { count: 0, addresses: [] };
          }
          if (!makers["0"].addresses.includes(c.address)) {
            makers["0"].addresses.push(c.address);
            makers["0"].count++;
          }
        }
      }
    }

    const intents = this.store.getIntentStats();

    return { makers, intents };
  }
}
