import { createServer, type IncomingMessage } from "http";
import { WebSocketServer } from "ws";
import { Relay } from "./relay.js";

const MAX_MESSAGES_PER_WINDOW = 30; // messages per window per IP
const RATE_WINDOW_MS = 10_000;      // 10 second window
const MAX_CONNECTIONS_PER_IP = 5;

const messageCounts = new Map<string, { count: number; resetAt: number }>();
const connectionCounts = new Map<string, number>();

function getIP(req: IncomingMessage): string {
  const forwarded = req.headers["x-forwarded-for"];
  if (typeof forwarded === "string") return forwarded.split(",")[0].trim();
  return req.socket.remoteAddress ?? "unknown";
}

function isRateLimited(ip: string): boolean {
  const now = Date.now();
  const entry = messageCounts.get(ip);
  if (!entry || now > entry.resetAt) {
    messageCounts.set(ip, { count: 1, resetAt: now + RATE_WINDOW_MS });
    return false;
  }
  entry.count++;
  return entry.count > MAX_MESSAGES_PER_WINDOW;
}

export interface RelayServerOptions {
  port: number;
  host?: string;
}

export function startRelayServer(options: RelayServerOptions): {
  relay: Relay;
  close: () => void;
} {
  const relay = new Relay();

  const server = createServer((req, res) => {
    const cors: Record<string, string> = {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type",
    };

    if (req.method === "OPTIONS") {
      res.writeHead(204, cors);
      res.end();
      return;
    }

    if (req.method === "GET" && req.url === "/health") {
      res.writeHead(200, { ...cors, "Content-Type": "application/json" });
      res.end(JSON.stringify({ status: "ok" }));
      return;
    }

    if (req.method === "GET" && req.url === "/intents") {
      const intents = relay.getStore().getOpenIntents();
      res.writeHead(200, { ...cors, "Content-Type": "application/json" });
      res.end(
        JSON.stringify(
          intents.map((s) => ({
            ...s.intent,
            quoteCount: s.quotes.size,
            selectedMaker: s.selectedMaker,
          })),
        ),
      );
      return;
    }

    res.writeHead(404, cors);
    res.end("Not found");
  });

  const wss = new WebSocketServer({
    server,
    maxPayload: 16 * 1024, // 16KB max message size
    verifyClient: ({ req }, cb) => {
      const ip = getIP(req);
      const count = connectionCounts.get(ip) ?? 0;
      if (count >= MAX_CONNECTIONS_PER_IP) {
        cb(false, 429, "Too many connections");
        return;
      }
      connectionCounts.set(ip, count + 1);
      cb(true);
    },
  });

  wss.on("connection", (ws, req) => {
    const ip = getIP(req);

    // Wrap the ws.send to inject rate limiting on inbound messages
    const origEmit = ws.emit.bind(ws);
    ws.emit = function (event: string, ...args: unknown[]) {
      if (event === "message" && isRateLimited(ip)) {
        ws.send(JSON.stringify({ type: "error", data: { message: "Rate limited" } }));
        return false;
      }
      return origEmit(event, ...args);
    } as typeof ws.emit;

    ws.on("close", () => {
      const c = connectionCounts.get(ip) ?? 1;
      if (c <= 1) connectionCounts.delete(ip);
      else connectionCounts.set(ip, c - 1);
    });
  });

  relay.attach(wss);

  server.listen(options.port, options.host ?? "0.0.0.0", () => {
    console.log(`Relay listening on ${options.host ?? "0.0.0.0"}:${options.port}`);
  });

  return {
    relay,
    close: () => {
      relay.stop();
      wss.close();
      server.close();
    },
  };
}
