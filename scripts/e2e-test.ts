#!/usr/bin/env tsx
/**
 * E2E test: full settlement loop on two local Anvil instances.
 *
 * 1. Start two Anvil instances (source chain + dest chain)
 * 2. Deploy contracts on both chains
 * 3. Fund maker + taker
 * 4. Start relay
 * 5. Start maker bot
 * 6. Taker creates intent → maker quotes → taker selects → maker fills → settlement
 */

import { spawn, execSync, ChildProcess } from "child_process";
import {
  createPublicClient,
  createWalletClient,
  http,
  parseAbi,
  parseAbiItem,
  decodeEventLog,
  erc20Abi,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { foundry } from "viem/chains";
import WebSocket from "ws";
import { startRelayServer } from "../packages/relay/src/server.js";
import { GauloiEscrowAbi, GauloiStakingAbi, signQuote } from "@gauloi/common";

// Test accounts (Anvil defaults)
const DEPLOYER_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" as const;
const MAKER_KEY = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d" as const;
const TAKER_KEY = "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a" as const;

const deployer = privateKeyToAccount(DEPLOYER_KEY);
const maker = privateKeyToAccount(MAKER_KEY);
const taker = privateKeyToAccount(TAKER_KEY);

const SOURCE_PORT = 8545;
const DEST_PORT = 8546;
const RELAY_PORT = 8080;

const SOURCE_RPC = `http://127.0.0.1:${SOURCE_PORT}`;
const DEST_RPC = `http://127.0.0.1:${DEST_PORT}`;

const processes: ChildProcess[] = [];

function cleanup() {
  for (const p of processes) {
    p.kill("SIGTERM");
  }
}

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function startAnvil(port: number, chainId: number): Promise<ChildProcess> {
  return new Promise((resolve, reject) => {
    const anvil = spawn("anvil", [
      "--port", port.toString(),
      "--chain-id", chainId.toString(),
      "--block-time", "1",
      "--silent",
    ]);
    processes.push(anvil);

    anvil.stderr.on("data", (data: Buffer) => {
      const msg = data.toString();
      if (msg.includes("error")) {
        reject(new Error(`Anvil failed: ${msg}`));
      }
    });

    // Give Anvil time to start
    setTimeout(() => resolve(anvil), 1000);
  });
}

function deployContracts(rpcUrl: string, settlementWindow: number): string {
  const result = execSync(
    `cd /Users/cdrn/Code/gauloi-v2/contracts && ` +
    `DEPLOYER_KEY=${DEPLOYER_KEY} ` +
    `SETTLEMENT_WINDOW=${settlementWindow} ` +
    `forge script script/Deploy.s.sol:Deploy ` +
    `--rpc-url ${rpcUrl} --broadcast 2>&1`,
    { encoding: "utf-8" },
  );
  return result;
}

function parseDeployOutput(output: string): Record<string, `0x${string}`> {
  const addresses: Record<string, `0x${string}`> = {};
  const lines = output.split("\n");
  for (const line of lines) {
    const match = line.match(/(USDC|Staking|Escrow|Disputes):\s+(0x[a-fA-F0-9]+)/);
    if (match) {
      addresses[match[1]] = match[2] as `0x${string}`;
    }
  }
  return addresses;
}

async function main() {
  console.log("=== Gauloi v2 E2E Test ===\n");

  // 1. Start Anvil instances
  console.log("Starting Anvil instances...");
  await startAnvil(SOURCE_PORT, 1);
  await startAnvil(DEST_PORT, 42161);
  console.log("  Source chain (Ethereum): port", SOURCE_PORT);
  console.log("  Dest chain (Arbitrum):   port", DEST_PORT);

  // Create clients
  const sourceChain = { ...foundry, id: 1 as const };
  const destChain = { ...foundry, id: 42161 as const };

  const sourcePublic = createPublicClient({ chain: sourceChain, transport: http(SOURCE_RPC) });
  const destPublic = createPublicClient({ chain: destChain, transport: http(DEST_RPC) });
  const deployerSourceWallet = createWalletClient({ account: deployer, chain: sourceChain, transport: http(SOURCE_RPC) });
  const deployerDestWallet = createWalletClient({ account: deployer, chain: destChain, transport: http(DEST_RPC) });

  // 2. Deploy contracts
  console.log("\nDeploying contracts on source chain...");
  const sourceOutput = deployContracts(SOURCE_RPC, 10); // 10s settlement for testing
  const sourceAddrs = parseDeployOutput(sourceOutput);
  console.log("  Source contracts:", sourceAddrs);

  console.log("Deploying contracts on dest chain...");
  const destOutput = deployContracts(DEST_RPC, 10);
  const destAddrs = parseDeployOutput(destOutput);
  console.log("  Dest contracts:", destAddrs);

  if (!sourceAddrs.USDC || !sourceAddrs.Staking || !sourceAddrs.Escrow) {
    console.error("Failed to deploy contracts. Output:", sourceOutput);
    cleanup();
    process.exit(1);
  }

  // 3. Fund accounts with mock USDC
  console.log("\nFunding accounts...");
  const mockMintAbi = parseAbi(["function mint(address to, uint256 amount) external"]);

  // Mint USDC on source chain for taker (to create intents) and maker (for staking)
  await deployerSourceWallet.writeContract({
    address: sourceAddrs.USDC,
    abi: mockMintAbi,
    functionName: "mint",
    args: [taker.address, 1_000_000n * 10n ** 6n],
  });
  await deployerSourceWallet.writeContract({
    address: sourceAddrs.USDC,
    abi: mockMintAbi,
    functionName: "mint",
    args: [maker.address, 1_000_000n * 10n ** 6n],
  });

  // Mint USDC on dest chain for maker (to fill orders)
  await deployerDestWallet.writeContract({
    address: destAddrs.USDC,
    abi: mockMintAbi,
    functionName: "mint",
    args: [maker.address, 1_000_000n * 10n ** 6n],
  });

  console.log("  Taker funded: 1M USDC (source)");
  console.log("  Maker funded: 1M USDC (source + dest)");

  // 4. Maker stakes on source chain
  console.log("\nMaker staking...");
  const makerSourceWallet = createWalletClient({ account: maker, chain: sourceChain, transport: http(SOURCE_RPC) });

  await makerSourceWallet.writeContract({
    address: sourceAddrs.USDC,
    abi: erc20Abi,
    functionName: "approve",
    args: [sourceAddrs.Staking, 100_000n * 10n ** 6n],
  });
  await makerSourceWallet.writeContract({
    address: sourceAddrs.Staking,
    abi: GauloiStakingAbi,
    functionName: "stake",
    args: [100_000n * 10n ** 6n],
  });
  console.log("  Maker staked 100,000 USDC");

  // 5. Start relay
  console.log("\nStarting relay on port", RELAY_PORT, "...");
  const { close: closeRelay } = startRelayServer({ port: RELAY_PORT });

  await sleep(500);

  // 6. Taker creates intent on-chain
  console.log("\nTaker creating intent...");
  const takerSourceWallet = createWalletClient({ account: taker, chain: sourceChain, transport: http(SOURCE_RPC) });
  const makerDestWallet = createWalletClient({ account: maker, chain: destChain, transport: http(DEST_RPC) });

  const inputAmount = 10_000n * 10n ** 6n; // 10,000 USDC
  const minOutput = 9_950n * 10n ** 6n;    // 9,950 USDC min (allows 50 bps spread)
  const expiry = BigInt(Math.floor(Date.now() / 1000) + 3600);

  // Approve
  await takerSourceWallet.writeContract({
    address: sourceAddrs.USDC,
    abi: erc20Abi,
    functionName: "approve",
    args: [sourceAddrs.Escrow, inputAmount],
  });

  // Create intent
  const createTx = await takerSourceWallet.writeContract({
    address: sourceAddrs.Escrow,
    abi: GauloiEscrowAbi,
    functionName: "createIntent",
    args: [
      sourceAddrs.USDC,
      inputAmount,
      destAddrs.USDC,
      minOutput,
      42161n,
      taker.address,
      expiry,
    ],
  });

  const createReceipt = await sourcePublic.waitForTransactionReceipt({ hash: createTx });

  // Find the IntentCreated log from the escrow contract
  const intentCreatedLog = createReceipt.logs.find(
    (log) => log.address.toLowerCase() === sourceAddrs.Escrow.toLowerCase() && log.topics.length >= 2,
  );
  if (!intentCreatedLog) {
    console.error("Failed to find IntentCreated log in receipt");
    cleanup();
    process.exit(1);
  }
  const intentId = intentCreatedLog.topics[1] as `0x${string}`;
  console.log("  Intent created:", intentId);

  // 7. Simulate the RFQ flow via WebSocket
  console.log("\nStarting RFQ flow...");

  // Connect maker to relay
  const makerWs = new WebSocket(`ws://127.0.0.1:${RELAY_PORT}`);
  await new Promise<void>((resolve) => makerWs.on("open", resolve));

  makerWs.send(JSON.stringify({
    type: "maker_subscribe",
    data: { address: maker.address },
  }));

  // Connect taker to relay
  const takerWs = new WebSocket(`ws://127.0.0.1:${RELAY_PORT}`);
  await new Promise<void>((resolve) => takerWs.on("open", resolve));

  // Set up handlers for the flow
  const flowComplete = new Promise<void>((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error("Flow timed out after 30s")), 30_000);

    // Maker handles new intents
    makerWs.on("message", async (raw) => {
      const msg = JSON.parse(raw.toString());

      if (msg.type === "new_intent") {
        console.log("  Maker received intent, signing and sending quote...");
        const outputAmount = 9_970n * 10n ** 6n; // 9,970 USDC (30 bps spread)
        const quoteExpiry = Math.floor(Date.now() / 1000) + 300;

        const signature = await signQuote(makerSourceWallet as any, {
          intentId: msg.data.intentId as `0x${string}`,
          maker: maker.address,
          outputAmount,
          estimatedFillTime: 10,
          expiry: quoteExpiry,
        });

        makerWs.send(JSON.stringify({
          type: "maker_quote",
          data: {
            intentId: msg.data.intentId,
            maker: maker.address,
            outputAmount: outputAmount.toString(),
            estimatedFillTime: 10,
            expiry: quoteExpiry,
            signature,
          },
        }));
      }

      if (msg.type === "quote_accepted") {
        console.log("  Maker's quote accepted, executing fill...");

        try {
          // Commit on source chain
          console.log("    Committing to intent...");
          const commitTx = await makerSourceWallet.writeContract({
            address: sourceAddrs.Escrow,
            abi: GauloiEscrowAbi,
            functionName: "commitToIntent",
            args: [intentId],
          });
          await sourcePublic.waitForTransactionReceipt({ hash: commitTx });

          // Fill on dest chain (transfer USDC to taker)
          console.log("    Filling on destination chain...");
          const fillAmount = 9_970n * 10n ** 6n;
          const fillTx = await makerDestWallet.writeContract({
            address: destAddrs.USDC,
            abi: erc20Abi,
            functionName: "transfer",
            args: [taker.address, fillAmount],
          });
          const fillReceipt = await destPublic.waitForTransactionReceipt({ hash: fillTx });

          // Submit fill evidence on source chain
          console.log("    Submitting fill evidence...");
          const submitTx = await makerSourceWallet.writeContract({
            address: sourceAddrs.Escrow,
            abi: GauloiEscrowAbi,
            functionName: "submitFill",
            args: [intentId, fillReceipt.transactionHash],
          });
          await sourcePublic.waitForTransactionReceipt({ hash: submitTx });

          console.log("  Fill submitted, waiting for settlement window...");

          // Wait for settlement window (10 seconds + buffer)
          await sleep(12_000);

          // Settle
          console.log("    Settling...");
          const settleTx = await makerSourceWallet.writeContract({
            address: sourceAddrs.Escrow,
            abi: GauloiEscrowAbi,
            functionName: "settle",
            args: [intentId],
          });
          await sourcePublic.waitForTransactionReceipt({ hash: settleTx });

          console.log("  Settlement complete!");
          clearTimeout(timeout);
          resolve();
        } catch (err) {
          clearTimeout(timeout);
          reject(err);
        }
      }
    });

    // Taker handles quotes
    takerWs.on("message", (raw) => {
      const msg = JSON.parse(raw.toString());

      if (msg.type === "quote_received") {
        console.log(`  Taker received quote: ${msg.data.outputAmount} from ${msg.data.maker}`);
        console.log("  Taker selecting quote...");
        takerWs.send(JSON.stringify({
          type: "quote_select",
          data: {
            intentId,
            maker: msg.data.maker,
          },
        }));
      }
    });
  });

  // Broadcast intent to relay
  console.log("  Taker broadcasting intent to relay...");
  takerWs.send(JSON.stringify({
    type: "intent_broadcast",
    data: {
      intentId,
      taker: taker.address,
      inputToken: sourceAddrs.USDC,
      inputAmount: inputAmount.toString(),
      outputToken: destAddrs.USDC,
      destinationChainId: 42161,
      destinationAddress: taker.address,
      minOutputAmount: minOutput.toString(),
      expiry: Number(expiry),
      sourceChainId: 1,
    },
  }));

  try {
    await flowComplete;

    // 8. Verify final state
    console.log("\n=== Verifying Final State ===");

    // Check intent state
    const intent = await sourcePublic.readContract({
      address: sourceAddrs.Escrow,
      abi: GauloiEscrowAbi,
      functionName: "getIntent",
      args: [intentId],
    }) as any;
    console.log(`  Intent state: ${intent.state} (3 = Settled)`);

    // Check taker received USDC on dest chain
    const takerDestBalance = await destPublic.readContract({
      address: destAddrs.USDC,
      abi: erc20Abi,
      functionName: "balanceOf",
      args: [taker.address],
    });
    console.log(`  Taker dest balance: ${Number(takerDestBalance) / 1e6} USDC`);

    // Check maker received escrowed USDC on source chain
    const makerSourceBalance = await sourcePublic.readContract({
      address: sourceAddrs.USDC,
      abi: erc20Abi,
      functionName: "balanceOf",
      args: [maker.address],
    });
    console.log(`  Maker source balance: ${Number(makerSourceBalance) / 1e6} USDC`);

    // Check exposure released
    const capacity = await sourcePublic.readContract({
      address: sourceAddrs.Staking,
      abi: GauloiStakingAbi,
      functionName: "availableCapacity",
      args: [maker.address],
    });
    console.log(`  Maker available capacity: ${Number(capacity) / 1e6} USDC`);

    const allPassed = intent.state === 3 && takerDestBalance > 0n;
    console.log(`\n=== E2E Test ${allPassed ? "PASSED" : "FAILED"} ===`);

    process.exitCode = allPassed ? 0 : 1;
  } catch (err) {
    console.error("\n=== E2E Test FAILED ===");
    console.error(err);
    process.exitCode = 1;
  } finally {
    // Cleanup
    makerWs.close();
    takerWs.close();
    closeRelay();
    cleanup();
  }
}

main().catch((err) => {
  console.error(err);
  cleanup();
  process.exit(1);
});
