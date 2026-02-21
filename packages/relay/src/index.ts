import { startRelayServer } from "./server.js";

const port = parseInt(process.env.RELAY_PORT ?? "8080", 10);

const { close } = startRelayServer({ port });

process.on("SIGINT", () => {
  console.log("\nShutting down relay...");
  close();
  process.exit(0);
});
