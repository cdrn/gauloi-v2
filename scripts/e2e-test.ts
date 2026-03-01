#!/usr/bin/env tsx
/**
 * E2E tests: full settlement loop + dispute fraud path on two local Anvil instances.
 *
 * Test 1 (Happy Path):
 *   Taker creates intent → maker quotes → taker selects → maker fills → settlement
 *
 * Test 2 (Dispute — Fraud):
 *   Maker submits fake fill → another maker disputes → attestor signs → resolution → slashing + refund
 */

import { spawn, execSync, ChildProcess } from "child_process";
import {
  createPublicClient,
  createWalletClient,
  http,
  parseAbi,
  erc20Abi,
  keccak256,
  encodePacked,
  type PublicClient,
  type WalletClient,
  type Transport,
  type Chain,
} from "viem";
import { privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";
import { foundry } from "viem/chains";
import WebSocket from "ws";
import { startRelayServer } from "../packages/relay/src/server.js";
import {
  GauloiEscrowAbi,
  GauloiStakingAbi,
  GauloiDisputesAbi,
  signQuote,
} from "@gauloi/common";

// ── Anvil default accounts ──────────────────────────────────────────────────

const DEPLOYER_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" as const;
const MAKER1_KEY  = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d" as const;
const TAKER_KEY   = "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a" as const;
const MAKER2_KEY  = "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6" as const;
const MAKER3_KEY  = "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a" as const;

const deployer = privateKeyToAccount(DEPLOYER_KEY);
const maker1   = privateKeyToAccount(MAKER1_KEY);
const taker    = privateKeyToAccount(TAKER_KEY);
const maker2   = privateKeyToAccount(MAKER2_KEY);
const maker3   = privateKeyToAccount(MAKER3_KEY);

const SOURCE_PORT = 8545;
const DEST_PORT = 8546;
const RELAY_PORT = 8080;

const SOURCE_RPC = `http://127.0.0.1:${SOURCE_PORT}`;
const DEST_RPC = `http://127.0.0.1:${DEST_PORT}`;

const processes: ChildProcess[] = [];
const mockMintAbi = parseAbi(["function mint(address to, uint256 amount) external"]);

// ── Helpers ─────────────────────────────────────────────────────────────────

function cleanup() {
  for (const p of processes) p.kill("SIGTERM");
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
      if (data.toString().includes("error")) reject(new Error(`Anvil: ${data}`));
    });
    setTimeout(() => resolve(anvil), 1000);
  });
}

function deployContracts(rpcUrl: string, settlementWindow: number): string {
  return execSync(
    `cd /Users/cdrn/Code/gauloi-v2/contracts && ` +
    `DEPLOYER_KEY=${DEPLOYER_KEY} ` +
    `SETTLEMENT_WINDOW=${settlementWindow} ` +
    `forge script script/Deploy.s.sol:Deploy ` +
    `--rpc-url ${rpcUrl} --broadcast 2>&1`,
    { encoding: "utf-8" },
  );
}

function parseDeployOutput(output: string): Record<string, `0x${string}`> {
  const addresses: Record<string, `0x${string}`> = {};
  for (const line of output.split("\n")) {
    const m = line.match(/(USDC|Staking|Escrow|Disputes):\s+(0x[a-fA-F0-9]+)/);
    if (m) addresses[m[1]] = m[2] as `0x${string}`;
  }
  return addresses;
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

async function mintUSDC(
  wallet: WalletClient<Transport, Chain, PrivateKeyAccount>,
  token: `0x${string}`,
  to: `0x${string}`,
  amount: bigint,
) {
  await wallet.writeContract({ address: token, abi: mockMintAbi, functionName: "mint", args: [to, amount] });
}

async function stakeFor(
  wallet: WalletClient<Transport, Chain, PrivateKeyAccount>,
  publicClient: PublicClient<Transport, Chain>,
  token: `0x${string}`,
  staking: `0x${string}`,
  amount: bigint,
) {
  const approveTx = await wallet.writeContract({
    address: token, abi: erc20Abi, functionName: "approve", args: [staking, amount],
  });
  await publicClient.waitForTransactionReceipt({ hash: approveTx });
  const stakeTx = await wallet.writeContract({
    address: staking, abi: GauloiStakingAbi, functionName: "stake", args: [amount],
  });
  await publicClient.waitForTransactionReceipt({ hash: stakeTx });
}

// ── Shared context ──────────────────────────────────────────────────────────

interface Ctx {
  sourceChain: Chain;
  destChain: Chain;
  sourcePublic: PublicClient<Transport, Chain>;
  destPublic: PublicClient<Transport, Chain>;
  deployerSourceWallet: WalletClient<Transport, Chain, PrivateKeyAccount>;
  deployerDestWallet: WalletClient<Transport, Chain, PrivateKeyAccount>;
  sourceAddrs: Record<string, `0x${string}`>;
  destAddrs: Record<string, `0x${string}`>;
  closeRelay: () => void;
}

// ── Test 1: Happy Path ──────────────────────────────────────────────────────

async function testHappyPath(ctx: Ctx): Promise<boolean> {
  console.log("\n╔══════════════════════════════════════╗");
  console.log("║    Test 1: Happy Path Settlement     ║");
  console.log("╚══════════════════════════════════════╝\n");

  const { sourcePublic, destPublic, sourceAddrs, destAddrs, sourceChain, destChain } = ctx;

  const maker1SourceWallet = createWalletClient({ account: maker1, chain: sourceChain, transport: http(SOURCE_RPC) });
  const maker1DestWallet = createWalletClient({ account: maker1, chain: destChain, transport: http(DEST_RPC) });
  const takerSourceWallet = createWalletClient({ account: taker, chain: sourceChain, transport: http(SOURCE_RPC) });

  // Create intent
  const inputAmount = 10_000n * 10n ** 6n;
  const minOutput = 9_950n * 10n ** 6n;
  const expiry = BigInt(Math.floor(Date.now() / 1000) + 3600);

  const approveTx = await takerSourceWallet.writeContract({
    address: sourceAddrs.USDC, abi: erc20Abi, functionName: "approve",
    args: [sourceAddrs.Escrow, inputAmount],
  });
  await sourcePublic.waitForTransactionReceipt({ hash: approveTx });

  const createTx = await takerSourceWallet.writeContract({
    address: sourceAddrs.Escrow, abi: GauloiEscrowAbi, functionName: "createIntent",
    args: [sourceAddrs.USDC, inputAmount, destAddrs.USDC, minOutput, 42161n, taker.address, expiry],
  });
  const createReceipt = await sourcePublic.waitForTransactionReceipt({ hash: createTx });
  const intentId = findIntentId(createReceipt, sourceAddrs.Escrow);
  console.log("  Intent created:", intentId);

  // RFQ flow via WebSocket
  const makerWs = new WebSocket(`ws://127.0.0.1:${RELAY_PORT}`);
  await new Promise<void>((r) => makerWs.on("open", r));
  makerWs.send(JSON.stringify({ type: "maker_subscribe", data: { address: maker1.address } }));

  const takerWs = new WebSocket(`ws://127.0.0.1:${RELAY_PORT}`);
  await new Promise<void>((r) => takerWs.on("open", r));

  const flowComplete = new Promise<void>((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error("Flow timed out")), 30_000);

    makerWs.on("message", async (raw) => {
      const msg = JSON.parse(raw.toString());

      if (msg.type === "new_intent") {
        console.log("  Maker quoting...");
        const outputAmount = 9_970n * 10n ** 6n;
        const quoteExpiry = Math.floor(Date.now() / 1000) + 300;
        const signature = await signQuote(maker1SourceWallet as any, {
          intentId: msg.data.intentId as `0x${string}`, maker: maker1.address,
          outputAmount, estimatedFillTime: 10, expiry: quoteExpiry,
        });
        makerWs.send(JSON.stringify({
          type: "maker_quote",
          data: { intentId: msg.data.intentId, maker: maker1.address,
            outputAmount: outputAmount.toString(), estimatedFillTime: 10,
            expiry: quoteExpiry, signature },
        }));
      }

      if (msg.type === "quote_accepted") {
        try {
          console.log("  Committing...");
          const c = await maker1SourceWallet.writeContract({
            address: sourceAddrs.Escrow, abi: GauloiEscrowAbi, functionName: "commitToIntent", args: [intentId],
          });
          await sourcePublic.waitForTransactionReceipt({ hash: c });

          console.log("  Filling on dest chain...");
          const f = await maker1DestWallet.writeContract({
            address: destAddrs.USDC, abi: erc20Abi, functionName: "transfer",
            args: [taker.address, 9_970n * 10n ** 6n],
          });
          const fReceipt = await destPublic.waitForTransactionReceipt({ hash: f });

          console.log("  Submitting fill evidence...");
          const s = await maker1SourceWallet.writeContract({
            address: sourceAddrs.Escrow, abi: GauloiEscrowAbi, functionName: "submitFill",
            args: [intentId, fReceipt.transactionHash],
          });
          await sourcePublic.waitForTransactionReceipt({ hash: s });

          console.log("  Waiting for settlement window (10s)...");
          await sleep(12_000);

          console.log("  Settling...");
          const st = await maker1SourceWallet.writeContract({
            address: sourceAddrs.Escrow, abi: GauloiEscrowAbi, functionName: "settle", args: [intentId],
          });
          await sourcePublic.waitForTransactionReceipt({ hash: st });

          clearTimeout(timeout);
          resolve();
        } catch (err) { clearTimeout(timeout); reject(err); }
      }
    });

    takerWs.on("message", (raw) => {
      const msg = JSON.parse(raw.toString());
      if (msg.type === "quote_received") {
        console.log(`  Taker selecting quote from ${msg.data.maker}...`);
        takerWs.send(JSON.stringify({ type: "quote_select", data: { intentId, maker: msg.data.maker } }));
      }
    });
  });

  takerWs.send(JSON.stringify({
    type: "intent_broadcast",
    data: {
      intentId, taker: taker.address, inputToken: sourceAddrs.USDC,
      inputAmount: inputAmount.toString(), outputToken: destAddrs.USDC,
      destinationChainId: 42161, destinationAddress: taker.address,
      minOutputAmount: minOutput.toString(), expiry: Number(expiry), sourceChainId: 1,
    },
  }));

  await flowComplete;
  makerWs.close();
  takerWs.close();

  // Verify
  const intent = await sourcePublic.readContract({
    address: sourceAddrs.Escrow, abi: GauloiEscrowAbi, functionName: "getIntent", args: [intentId],
  }) as any;

  const passed = intent.state === 3;
  console.log(`\n  Intent state: ${intent.state} (3 = Settled) — ${passed ? "PASS" : "FAIL"}`);
  return passed;
}

// ── Test 2: Dispute (Fraud) ─────────────────────────────────────────────────

async function testDisputeFraud(ctx: Ctx): Promise<boolean> {
  console.log("\n╔══════════════════════════════════════╗");
  console.log("║    Test 2: Dispute — Fake Fill       ║");
  console.log("╚══════════════════════════════════════╝\n");

  const { sourcePublic, sourceAddrs, destAddrs, sourceChain, deployerSourceWallet } = ctx;

  const maker1Wallet = createWalletClient({ account: maker1, chain: sourceChain, transport: http(SOURCE_RPC) });
  const maker2Wallet = createWalletClient({ account: maker2, chain: sourceChain, transport: http(SOURCE_RPC) });
  const maker3Wallet = createWalletClient({ account: maker3, chain: sourceChain, transport: http(SOURCE_RPC) });
  const takerWallet  = createWalletClient({ account: taker, chain: sourceChain, transport: http(SOURCE_RPC) });

  // Fund and stake maker2 + maker3
  console.log("  Funding and staking maker2 + maker3...");
  for (const m of [maker2, maker3]) {
    await mintUSDC(deployerSourceWallet, sourceAddrs.USDC, m.address, 200_000n * 10n ** 6n);
    await stakeFor(
      createWalletClient({ account: m, chain: sourceChain, transport: http(SOURCE_RPC) }),
      sourcePublic, sourceAddrs.USDC, sourceAddrs.Staking, 100_000n * 10n ** 6n,
    );
    console.log(`    ${m.address.slice(0, 10)}... staked 100k`);
  }

  // Record maker1 stake before
  const maker1StakeBefore = await sourcePublic.readContract({
    address: sourceAddrs.Staking, abi: GauloiStakingAbi, functionName: "availableCapacity",
    args: [maker1.address],
  }) as bigint;

  // 1. Taker creates intent
  console.log("\n  Taker creating intent...");
  const inputAmount = 10_000n * 10n ** 6n;
  const minOutput = 9_950n * 10n ** 6n;
  const expiry = BigInt(Math.floor(Date.now() / 1000) + 3600);

  const a = await takerWallet.writeContract({
    address: sourceAddrs.USDC, abi: erc20Abi, functionName: "approve",
    args: [sourceAddrs.Escrow, inputAmount],
  });
  await sourcePublic.waitForTransactionReceipt({ hash: a });

  const createTx = await takerWallet.writeContract({
    address: sourceAddrs.Escrow, abi: GauloiEscrowAbi, functionName: "createIntent",
    args: [sourceAddrs.USDC, inputAmount, destAddrs.USDC, minOutput, 42161n, taker.address, expiry],
  });
  const createReceipt = await sourcePublic.waitForTransactionReceipt({ hash: createTx });
  const intentId = findIntentId(createReceipt, sourceAddrs.Escrow);
  console.log("  Intent:", intentId);

  // Record taker balance AFTER escrow (funds locked)
  const takerBalanceBefore = await sourcePublic.readContract({
    address: sourceAddrs.USDC, abi: erc20Abi, functionName: "balanceOf", args: [taker.address],
  }) as bigint;

  // 2. Maker1 (fraudster) commits
  console.log("  Maker1 committing to intent...");
  const commitTx = await maker1Wallet.writeContract({
    address: sourceAddrs.Escrow, abi: GauloiEscrowAbi, functionName: "commitToIntent", args: [intentId],
  });
  await sourcePublic.waitForTransactionReceipt({ hash: commitTx });

  // 3. Maker1 submits FAKE fill — a completely bogus tx hash
  const fakeTxHash = keccak256(encodePacked(["string"], ["this-fill-never-happened"]));
  console.log("  Maker1 submitting FAKE fill:", fakeTxHash.slice(0, 18) + "...");
  const fillTx = await maker1Wallet.writeContract({
    address: sourceAddrs.Escrow, abi: GauloiEscrowAbi, functionName: "submitFill",
    args: [intentId, fakeTxHash],
  });
  await sourcePublic.waitForTransactionReceipt({ hash: fillTx });

  // Verify intent is now in Filled state
  const intentAfterFill = await sourcePublic.readContract({
    address: sourceAddrs.Escrow, abi: GauloiEscrowAbi, functionName: "getIntent", args: [intentId],
  }) as any;
  console.log(`  Intent state after fill: ${intentAfterFill.state} (2 = Filled)`);

  // 4. Maker2 disputes — calculate bond and approve
  console.log("\n  Maker2 raising dispute...");
  const bondAmount = await sourcePublic.readContract({
    address: sourceAddrs.Disputes, abi: GauloiDisputesAbi,
    functionName: "calculateDisputeBond", args: [inputAmount],
  }) as bigint;
  console.log(`    Bond required: ${Number(bondAmount) / 1e6} USDC`);

  const bondApproveTx = await maker2Wallet.writeContract({
    address: sourceAddrs.USDC, abi: erc20Abi, functionName: "approve",
    args: [sourceAddrs.Disputes, bondAmount],
  });
  await sourcePublic.waitForTransactionReceipt({ hash: bondApproveTx });

  const disputeTx = await maker2Wallet.writeContract({
    address: sourceAddrs.Disputes, abi: GauloiDisputesAbi, functionName: "dispute", args: [intentId],
  });
  await sourcePublic.waitForTransactionReceipt({ hash: disputeTx });
  console.log("    Dispute raised!");

  // Verify intent is now Disputed (state 4)
  const intentAfterDispute = await sourcePublic.readContract({
    address: sourceAddrs.Escrow, abi: GauloiEscrowAbi, functionName: "getIntent", args: [intentId],
  }) as any;
  console.log(`    Intent state: ${intentAfterDispute.state} (4 = Disputed)`);

  // 5. Maker3 signs EIP-712 attestation: fillValid = false
  console.log("\n  Maker3 signing attestation (fill invalid)...");

  // Must match SignatureLib.sol exactly
  const attestationSignature = await maker3Wallet.signTypedData({
    domain: {
      name: "GauloiDisputes",
      version: "1",
      chainId: 1,
      verifyingContract: sourceAddrs.Disputes,
    },
    types: {
      FillAttestation: [
        { name: "intentId", type: "bytes32" },
        { name: "fillValid", type: "bool" },
        { name: "fillTxHash", type: "bytes32" },
        { name: "destinationChainId", type: "uint256" },
      ],
    },
    primaryType: "FillAttestation",
    message: {
      intentId,
      fillValid: false,
      fillTxHash: fakeTxHash,
      destinationChainId: 42161n,
    },
  });
  console.log("    Attestation signed:", attestationSignature.slice(0, 18) + "...");

  // 6. Resolve dispute with attestation
  console.log("  Resolving dispute (fill invalid)...");
  const resolveTx = await maker2Wallet.writeContract({
    address: sourceAddrs.Disputes, abi: GauloiDisputesAbi, functionName: "resolveDispute",
    args: [intentId, false, [attestationSignature]],
  });
  await sourcePublic.waitForTransactionReceipt({ hash: resolveTx });
  console.log("    Dispute resolved!");

  // 7. Verify final state
  console.log("\n  Verifying...");

  // Intent should be Expired (state 5) — resolveInvalid refunds taker and sets state to Expired
  const intentFinal = await sourcePublic.readContract({
    address: sourceAddrs.Escrow, abi: GauloiEscrowAbi, functionName: "getIntent", args: [intentId],
  }) as any;
  console.log(`    Intent state: ${intentFinal.state} (5 = Expired/Refunded)`);

  // Maker1 should be slashed — capacity should be 0
  const maker1CapacityAfter = await sourcePublic.readContract({
    address: sourceAddrs.Staking, abi: GauloiStakingAbi, functionName: "availableCapacity",
    args: [maker1.address],
  }) as bigint;
  console.log(`    Maker1 capacity: ${Number(maker1CapacityAfter) / 1e6} USDC (was ${Number(maker1StakeBefore) / 1e6})`);

  // Taker should have gotten escrowed funds back
  const takerBalanceAfter = await sourcePublic.readContract({
    address: sourceAddrs.USDC, abi: erc20Abi, functionName: "balanceOf", args: [taker.address],
  }) as bigint;
  const takerRefunded = takerBalanceAfter > takerBalanceBefore;
  console.log(`    Taker balance: ${Number(takerBalanceAfter) / 1e6} USDC (was ${Number(takerBalanceBefore) / 1e6}) — ${takerRefunded ? "refunded" : "NOT refunded"}`);

  // Dispute record
  const dispute = await sourcePublic.readContract({
    address: sourceAddrs.Disputes, abi: GauloiDisputesAbi, functionName: "getDispute", args: [intentId],
  }) as any;
  console.log(`    Dispute resolved: ${dispute.resolved}, fillDeemedValid: ${dispute.fillDeemedValid}`);

  // Maker2 (challenger) should have gotten bond back + reward
  const maker2Balance = await sourcePublic.readContract({
    address: sourceAddrs.USDC, abi: erc20Abi, functionName: "balanceOf", args: [maker2.address],
  }) as bigint;
  console.log(`    Maker2 balance: ${Number(maker2Balance) / 1e6} USDC (got bond + slash reward)`);

  const passed =
    intentFinal.state === 5 &&           // Refunded
    maker1CapacityAfter === 0n &&         // Slashed
    takerRefunded &&                      // Taker refunded
    dispute.resolved === true &&
    dispute.fillDeemedValid === false;

  console.log(`\n  ${passed ? "PASS" : "FAIL"}`);
  return passed;
}

// ── Main ────────────────────────────────────────────────────────────────────

async function main() {
  console.log("=== Gauloi v2 E2E Tests ===");

  // Start Anvil
  console.log("\nStarting Anvil instances...");
  await startAnvil(SOURCE_PORT, 1);
  await startAnvil(DEST_PORT, 42161);

  const sourceChain = { ...foundry, id: 1 as const };
  const destChain = { ...foundry, id: 42161 as const };

  const sourcePublic = createPublicClient({ chain: sourceChain, transport: http(SOURCE_RPC) });
  const destPublic = createPublicClient({ chain: destChain, transport: http(DEST_RPC) });
  const deployerSourceWallet = createWalletClient({ account: deployer, chain: sourceChain, transport: http(SOURCE_RPC) });
  const deployerDestWallet = createWalletClient({ account: deployer, chain: destChain, transport: http(DEST_RPC) });

  // Deploy
  console.log("\nDeploying contracts...");
  const sourceAddrs = parseDeployOutput(deployContracts(SOURCE_RPC, 10));
  const destAddrs = parseDeployOutput(deployContracts(DEST_RPC, 10));
  console.log("  Source:", sourceAddrs);
  console.log("  Dest:  ", destAddrs);

  if (!sourceAddrs.USDC || !sourceAddrs.Escrow || !sourceAddrs.Disputes) {
    throw new Error("Deploy failed");
  }

  // Fund maker1 + taker
  console.log("\nFunding accounts...");
  await mintUSDC(deployerSourceWallet, sourceAddrs.USDC, taker.address, 1_000_000n * 10n ** 6n);
  await mintUSDC(deployerSourceWallet, sourceAddrs.USDC, maker1.address, 1_000_000n * 10n ** 6n);
  await mintUSDC(deployerDestWallet, destAddrs.USDC, maker1.address, 1_000_000n * 10n ** 6n);

  // Stake maker1
  console.log("Staking maker1...");
  await stakeFor(
    createWalletClient({ account: maker1, chain: sourceChain, transport: http(SOURCE_RPC) }),
    sourcePublic, sourceAddrs.USDC, sourceAddrs.Staking, 100_000n * 10n ** 6n,
  );

  // Start relay
  console.log("Starting relay...");
  const { close: closeRelay } = startRelayServer({ port: RELAY_PORT });
  await sleep(500);

  const ctx: Ctx = {
    sourceChain, destChain, sourcePublic, destPublic,
    deployerSourceWallet, deployerDestWallet,
    sourceAddrs, destAddrs, closeRelay,
  };

  let allPassed = true;

  try {
    // Test 1
    const t1 = await testHappyPath(ctx);
    allPassed &&= t1;

    // Test 2
    const t2 = await testDisputeFraud(ctx);
    allPassed &&= t2;

    console.log(`\n${"=".repeat(42)}`);
    console.log(`  ${allPassed ? "ALL TESTS PASSED" : "SOME TESTS FAILED"}`);
    console.log(`${"=".repeat(42)}`);

    process.exitCode = allPassed ? 0 : 1;
  } catch (err) {
    console.error("\n=== TEST ERROR ===");
    console.error(err);
    process.exitCode = 1;
  } finally {
    closeRelay();
    cleanup();
  }
}

main().catch((err) => {
  console.error(err);
  cleanup();
  process.exit(1);
});
