import { createServer } from "http";
import { WebSocketServer } from "ws";
import { Relay } from "./relay.js";

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

  const wss = new WebSocketServer({ server });
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
