import { Command } from "commander";
import { createIntent } from "./commands/create-intent.js";
import { listIntents } from "./commands/list-intents.js";
import { runMaker } from "./commands/run-maker.js";
import { status } from "./commands/status.js";

const program = new Command();

program
  .name("gauloi")
  .description("Gauloi v2 CLI — cross-chain stablecoin settlement")
  .version("0.1.0");

program
  .command("create-intent")
  .description("Create a new intent (act as taker)")
  .requiredOption("--input-token <address>", "Input token address")
  .requiredOption("--input-amount <amount>", "Input amount (in token units, e.g. 10000 for 10k USDC)")
  .requiredOption("--output-token <address>", "Desired output token address")
  .requiredOption("--min-output <amount>", "Minimum output amount")
  .requiredOption("--dest-chain <chainId>", "Destination chain ID")
  .requiredOption("--dest-address <address>", "Destination address")
  .option("--expiry <seconds>", "Expiry in seconds from now", "3600")
  .option("--source-chain <chainId>", "Source chain ID", "1")
  .option("--rpc <url>", "Source chain RPC URL", process.env.ETHEREUM_RPC_URL)
  .option("--escrow <address>", "Escrow contract address")
  .option("--private-key <key>", "Taker private key", process.env.PRIVATE_KEY)
  .option("--relay <url>", "Relay WebSocket URL", "ws://localhost:8080")
  .action(createIntent);

program
  .command("list-intents")
  .description("List open intents from the relay")
  .option("--relay <url>", "Relay HTTP URL", "http://localhost:8080")
  .action(listIntents);

program
  .command("status")
  .description("Show maker staking info")
  .requiredOption("--maker <address>", "Maker address")
  .option("--rpc <url>", "RPC URL", process.env.ETHEREUM_RPC_URL)
  .option("--staking <address>", "Staking contract address")
  .action(status);

program
  .command("run-maker")
  .description("Run a maker bot")
  .option("--private-key <key>", "Maker private key", process.env.PRIVATE_KEY)
  .requiredOption("--source-chain <chainId>", "Source chain ID")
  .requiredOption("--dest-chain <chainId>", "Destination chain ID")
  .option("--source-rpc <url>", "Source chain RPC URL")
  .option("--dest-rpc <url>", "Destination chain RPC URL")
  .option("--escrow <address>", "Escrow contract address override")
  .option("--staking <address>", "Staking contract address override")
  .option("--disputes <address>", "Disputes contract address override")
  .option("--relay <url>", "Relay WebSocket URL", "ws://localhost:8080")
  .option("--settle-interval <ms>", "Settlement check interval in ms", "30000")
  .option("--spread-clean <bps>", "Spread for clean addresses (bps)", "30")
  .option("--spread-unknown <bps>", "Spread for unknown addresses (bps)", "100")
  .option("--max-fill <usdc>", "Maximum fill size in USDC", "10000")
  .action(runMaker);

program.parse();
