#!/usr/bin/env tsx
/**
 * Testnet smoke test: full settlement loop on Sepolia → Arbitrum Sepolia.
 *
 * Prerequisites:
 *   1. Contracts deployed via scripts/deploy-testnet.sh
 *   2. deployments/sepolia.json and deployments/arbitrum-sepolia.json exist
 *   3. PRIVATE_KEY env var set (account with testnet ETH + USDC on both chains)
 *   4. Get testnet USDC from https://faucet.circle.com/
 *
 * Usage:
 *   PRIVATE_KEY=0x... npx tsx scripts/testnet-smoke.ts
 */

import { readFileSync } from "fs";
import { resolve } from "path";
import {
  createPublicClient,
  createWalletClient,
  http,
  erc20Abi,
  formatUnits,
  type PublicClient,
  type WalletClient,
  type Transport,
  type Chain,
} from "viem";
import { privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";
import { sepolia, arbitrumSepolia } from "viem/chains";
import WebSocket from "ws";
import { startRelayServer } from "../packages/relay/src/server.js";
import {
  GauloiEscrowAbi,
  GauloiStakingAbi,
  signQuote,
} from "@gauloi/common";

// ── Config ──────────────────────────────────────────────────────────────────

const PRIVATE_KEY = process.env.PRIVATE_KEY as `0x${string}`;
if (!PRIVATE_KEY) {
  console.error("Error: PRIVATE_KEY env var required");
  process.exit(1);
}

const SEPOLIA_RPC = process.env.SEPOLIA_RPC_URL ?? "https://ethereum-sepolia-rpc.publicnode.com";
const ARB_SEPOLIA_RPC = process.env.ARBITRUM_SEPOLIA_RPC_URL ?? "https://arbitrum-sepolia-rpc.publicnode.com";

const RELAY_PORT = 8080;

// Circle testnet USDC
const SEPOLIA_USDC = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238" as const;
const ARB_SEPOLIA_USDC = "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d" as const;

// ── Load deployments ────────────────────────────────────────────────────────

interface Deployment {
  usdc: `0x${string}`;
  staking: `0x${string}`;
  escrow: `0x${string}`;
  disputes: `0x${string}`;
}

function loadDeployment(name: string): Deployment {
  const path = resolve(__dirname, `../deployments/${name}.json`);
  try {
    return JSON.parse(readFileSync(path, "utf-8"));
  } catch {
    console.error(`Error: deployment file not found at ${path}`);
    console.error("Run scripts/deploy-testnet.sh first");
    process.exit(1);
  }
}

// ── Helpers ─────────────────────────────────────────────────────────────────

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

function findIntentId(
  receipt: { logs: readonly { address: string; topics: readonly string[] }[] },
  escrowAddr: string,
): `0x${string}` {
  const log = receipt.logs.find(
    (l) => l.address.toLowerCase() === escrowAddr.toLowerCase() && l.topics.length >= 2,
  );
  if (!log) throw new Error("IntentCreated log not found");
  return log.topics[1] as `0x${string}`;
}

async function checkBalance(
  publicClient: PublicClient<Transport, Chain>,
  token: `0x${string}`,
  address: `0x${string}`,
  label: string,
): Promise<bigint> {
  const balance = await publicClient.readContract({
    address: token,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [address],
  }) as bigint;
  console.log(`  ${label}: ${formatUnits(balance, 6)} USDC`);
  return balance;
}

async function checkETH(
  publicClient: PublicClient<Transport, Chain>,
  address: `0x${string}`,
  chain: string,
): Promise<bigint> {
  const balance = await publicClient.getBalance({ address });
  console.log(`  ${chain} ETH: ${formatUnits(balance, 18)}`);
  return balance;
}

// ── Main ────────────────────────────────────────────────────────────────────

async function main() {
  console.log("=== Gauloi v2 — Testnet Smoke Test ===\n");

  const account = privateKeyToAccount(PRIVATE_KEY);
  console.log(`Account: ${account.address}`);

  // Load deployments
  const sepoliaDeploy = loadDeployment("sepolia");
  const arbSepoliaDeploy = loadDeployment("arbitrum-sepolia");

  console.log(`\nSepolia contracts:`);
  console.log(`  Staking:  ${sepoliaDeploy.staking}`);
  console.log(`  Escrow:   ${sepoliaDeploy.escrow}`);
  console.log(`  Disputes: ${sepoliaDeploy.disputes}`);

  console.log(`\nArbitrum Sepolia contracts:`);
  console.log(`  Staking:  ${arbSepoliaDeploy.staking}`);
  console.log(`  Escrow:   ${arbSepoliaDeploy.escrow}`);
  console.log(`  Disputes: ${arbSepoliaDeploy.disputes}`);

  // Create clients
  const sepoliaPublic = createPublicClient({ chain: sepolia, transport: http(SEPOLIA_RPC) });
  const arbPublic = createPublicClient({ chain: arbitrumSepolia, transport: http(ARB_SEPOLIA_RPC) });
  const sepoliaWallet = createWalletClient({ account, chain: sepolia, transport: http(SEPOLIA_RPC) });
  const arbWallet = createWalletClient({ account, chain: arbitrumSepolia, transport: http(ARB_SEPOLIA_RPC) });

  // ── Step 1: Check balances ──
  console.log("\n── Step 1: Check balances ──");
  const sepoliaEth = await checkETH(sepoliaPublic, account.address, "Sepolia");
  const arbEth = await checkETH(arbPublic, account.address, "Arb Sepolia");
  const sepoliaUsdc = await checkBalance(sepoliaPublic, SEPOLIA_USDC, account.address, "Sepolia USDC");
  const arbUsdc = await checkBalance(arbPublic, ARB_SEPOLIA_USDC, account.address, "Arb Sepolia USDC");

  if (sepoliaEth === 0n) {
    console.error("\nError: No Sepolia ETH. Get some from a faucet.");
    process.exit(1);
  }
  if (arbEth === 0n) {
    console.error("\nError: No Arbitrum Sepolia ETH. Get some from a faucet.");
    process.exit(1);
  }
  if (sepoliaUsdc < 15_000_000n) { // 15 USDC minimum (10 stake + 5 intent)
    console.error("\nError: Need at least 15 USDC on Sepolia. Get some from https://faucet.circle.com/");
    process.exit(1);
  }
  if (arbUsdc < 5_000_000n) { // 5 USDC minimum for fill
    console.error("\nError: Need at least 5 USDC on Arbitrum Sepolia. Get some from https://faucet.circle.com/");
    process.exit(1);
  }

  // ── Step 2: Stake (if not already staked) ──
  console.log("\n── Step 2: Check/Create stake ──");
  const makerInfo = await sepoliaPublic.readContract({
    address: sepoliaDeploy.staking as `0x${string}`,
    abi: GauloiStakingAbi,
    functionName: "getMakerInfo",
    args: [account.address],
  }) as any;

  const stakedAmount = makerInfo.stakedAmount ?? makerInfo[0];
  const isActive = makerInfo.isActive ?? makerInfo[4];
  console.log(`  Current stake: ${formatUnits(stakedAmount, 6)} USDC, active: ${isActive}`);

  if (!isActive) {
    const stakeAmount = 10_000_000n; // 10 USDC (testnet min stake)
    console.log(`  Staking ${formatUnits(stakeAmount, 6)} USDC...`);

    const approveTx = await sepoliaWallet.writeContract({
      address: SEPOLIA_USDC,
      abi: erc20Abi,
      functionName: "approve",
      args: [sepoliaDeploy.staking as `0x${string}`, stakeAmount],
    });
    console.log(`  Approve tx: ${approveTx}`);
    await sepoliaPublic.waitForTransactionReceipt({ hash: approveTx });

    const stakeTx = await sepoliaWallet.writeContract({
      address: sepoliaDeploy.staking as `0x${string}`,
      abi: GauloiStakingAbi,
      functionName: "stake",
      args: [stakeAmount],
    });
    console.log(`  Stake tx: ${stakeTx}`);
    await sepoliaPublic.waitForTransactionReceipt({ hash: stakeTx });
    console.log("  Staked!");
  }

  // ── Step 3: Start relay ──
  console.log("\n── Step 3: Start relay ──");
  const { close: closeRelay } = startRelayServer({ port: RELAY_PORT });
  await sleep(500);
  console.log(`  Relay running on port ${RELAY_PORT}`);

  // ── Step 4: Create intent (acting as taker) ──
  console.log("\n── Step 4: Create intent ──");
  const inputAmount = 5_000_000n; // 5 USDC
  const minOutput = 4_950_000n; // 4.95 USDC
  const expiry = BigInt(Math.floor(Date.now() / 1000) + 3600);

  const approveIntentTx = await sepoliaWallet.writeContract({
    address: SEPOLIA_USDC,
    abi: erc20Abi,
    functionName: "approve",
    args: [sepoliaDeploy.escrow as `0x${string}`, inputAmount],
  });
  console.log(`  Approve tx: ${approveIntentTx}`);
  await sepoliaPublic.waitForTransactionReceipt({ hash: approveIntentTx });

  const createTx = await sepoliaWallet.writeContract({
    address: sepoliaDeploy.escrow as `0x${string}`,
    abi: GauloiEscrowAbi,
    functionName: "createIntent",
    args: [SEPOLIA_USDC, inputAmount, ARB_SEPOLIA_USDC, minOutput, 421614n, account.address, expiry],
  });
  console.log(`  Create intent tx: ${createTx}`);
  const createReceipt = await sepoliaPublic.waitForTransactionReceipt({ hash: createTx });
  const intentId = findIntentId(createReceipt, sepoliaDeploy.escrow);
  console.log(`  Intent ID: ${intentId}`);

  // ── Step 5: Self-quote via relay (acting as both maker and taker) ──
  console.log("\n── Step 5: RFQ flow (self-quoting) ──");

  const makerWs = new WebSocket(`ws://127.0.0.1:${RELAY_PORT}`);
  await new Promise<void>((r) => makerWs.on("open", r));
  makerWs.send(JSON.stringify({ type: "maker_subscribe", data: { address: account.address } }));

  const takerWs = new WebSocket(`ws://127.0.0.1:${RELAY_PORT}`);
  await new Promise<void>((r) => takerWs.on("open", r));

  const flowComplete = new Promise<void>((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error("Flow timed out (5 min)")), 300_000);

    makerWs.on("message", async (raw) => {
      const msg = JSON.parse(raw.toString());

      if (msg.type === "new_intent") {
        console.log("  Maker received intent, quoting...");
        const outputAmount = 4_970_000n; // 4.97 USDC
        const quoteExpiry = Math.floor(Date.now() / 1000) + 300;
        const signature = await signQuote(sepoliaWallet as any, {
          intentId: msg.data.intentId as `0x${string}`,
          maker: account.address,
          outputAmount,
          estimatedFillTime: 60,
          expiry: quoteExpiry,
        });
        makerWs.send(JSON.stringify({
          type: "maker_quote",
          data: {
            intentId: msg.data.intentId,
            maker: account.address,
            outputAmount: outputAmount.toString(),
            estimatedFillTime: 60,
            expiry: quoteExpiry,
            signature,
          },
        }));
      }

      if (msg.type === "quote_accepted") {
        try {
          // Commit on source chain
          console.log("  Committing to intent...");
          const commitTx = await sepoliaWallet.writeContract({
            address: sepoliaDeploy.escrow as `0x${string}`,
            abi: GauloiEscrowAbi,
            functionName: "commitToIntent",
            args: [intentId],
          });
          console.log(`  Commit tx: ${commitTx}`);
          await sepoliaPublic.waitForTransactionReceipt({ hash: commitTx });

          // Fill on destination chain (transfer USDC to self — we're both maker and taker)
          console.log("  Filling on Arbitrum Sepolia...");
          const fillTx = await arbWallet.writeContract({
            address: ARB_SEPOLIA_USDC,
            abi: erc20Abi,
            functionName: "transfer",
            args: [account.address, 4_970_000n],
          });
          console.log(`  Fill tx: ${fillTx}`);
          const fillReceipt = await arbPublic.waitForTransactionReceipt({ hash: fillTx });

          // Submit fill evidence on source chain
          console.log("  Submitting fill evidence...");
          const submitTx = await sepoliaWallet.writeContract({
            address: sepoliaDeploy.escrow as `0x${string}`,
            abi: GauloiEscrowAbi,
            functionName: "submitFill",
            args: [intentId, fillReceipt.transactionHash],
          });
          console.log(`  Submit fill tx: ${submitTx}`);
          await sepoliaPublic.waitForTransactionReceipt({ hash: submitTx });

          // Wait for settlement window (2 minutes on testnet)
          console.log("  Waiting for settlement window (2 minutes)...");
          await sleep(130_000); // 2min + 10s buffer

          // Settle
          console.log("  Settling...");
          const settleTx = await sepoliaWallet.writeContract({
            address: sepoliaDeploy.escrow as `0x${string}`,
            abi: GauloiEscrowAbi,
            functionName: "settle",
            args: [intentId],
          });
          console.log(`  Settle tx: ${settleTx}`);
          await sepoliaPublic.waitForTransactionReceipt({ hash: settleTx });

          clearTimeout(timeout);
          resolve();
        } catch (err) {
          clearTimeout(timeout);
          reject(err);
        }
      }
    });

    takerWs.on("message", (raw) => {
      const msg = JSON.parse(raw.toString());
      if (msg.type === "quote_received") {
        console.log(`  Taker received quote, selecting...`);
        takerWs.send(JSON.stringify({
          type: "quote_select",
          data: { intentId, maker: msg.data.maker },
        }));
      }
    });
  });

  // Broadcast intent
  takerWs.send(JSON.stringify({
    type: "intent_broadcast",
    data: {
      intentId,
      taker: account.address,
      inputToken: SEPOLIA_USDC,
      inputAmount: inputAmount.toString(),
      outputToken: ARB_SEPOLIA_USDC,
      destinationChainId: 421614,
      destinationAddress: account.address,
      minOutputAmount: minOutput.toString(),
      expiry: Number(expiry),
      sourceChainId: 11155111,
    },
  }));

  try {
    await flowComplete;
  } finally {
    makerWs.close();
    takerWs.close();
  }

  // ── Step 6: Verify ──
  console.log("\n── Step 6: Verify ──");
  const intent = await sepoliaPublic.readContract({
    address: sepoliaDeploy.escrow as `0x${string}`,
    abi: GauloiEscrowAbi,
    functionName: "getIntent",
    args: [intentId],
  }) as any;

  const state = intent.state ?? intent[9];
  const passed = state === 3;
  console.log(`  Intent state: ${state} (3 = Settled)`);
  console.log(`\n  ${passed ? "PASS — Full settlement loop complete on testnet!" : "FAIL"}`);

  // Final balances
  console.log("\n── Final balances ──");
  await checkBalance(sepoliaPublic, SEPOLIA_USDC, account.address, "Sepolia USDC");
  await checkBalance(arbPublic, ARB_SEPOLIA_USDC, account.address, "Arb Sepolia USDC");

  closeRelay();
  process.exit(passed ? 0 : 1);
}

main().catch((err) => {
  console.error("\n=== ERROR ===");
  console.error(err);
  process.exit(1);
});
