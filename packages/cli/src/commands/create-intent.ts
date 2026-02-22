import WebSocket from "ws";
import { erc20Abi } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import {
  GauloiEscrowAbi,
  getPublicClient,
  getWalletClient,
  SUPPORTED_CHAINS,
} from "@gauloi/common";

interface CreateIntentOptions {
  inputToken: string;
  inputAmount: string;
  outputToken: string;
  minOutput: string;
  destChain: string;
  destAddress: string;
  expiry: string;
  rpc?: string;
  escrow?: string;
  privateKey?: string;
  relay: string;
}

export async function createIntent(options: CreateIntentOptions): Promise<void> {
  if (!options.privateKey) {
    console.error("Error: --private-key or PRIVATE_KEY env var required");
    process.exit(1);
  }

  if (!options.rpc) {
    console.error("Error: --rpc or ETHEREUM_RPC_URL env var required");
    process.exit(1);
  }

  const account = privateKeyToAccount(options.privateKey as `0x${string}`);

  // Use chain ID 1 (Ethereum) as source by default
  const sourceChainConfig = {
    ...SUPPORTED_CHAINS[1]!,
    rpcUrl: options.rpc,
  };

  if (options.escrow) {
    sourceChainConfig.escrowAddress = options.escrow as `0x${string}`;
  }

  const publicClient = getPublicClient(sourceChainConfig);
  const walletClient = getWalletClient(sourceChainConfig, options.privateKey as `0x${string}`);

  const inputToken = options.inputToken as `0x${string}`;
  const inputAmount = BigInt(options.inputAmount);
  const outputToken = options.outputToken as `0x${string}`;
  const minOutput = BigInt(options.minOutput);
  const destChainId = BigInt(options.destChain);
  const destAddress = options.destAddress as `0x${string}`;
  const expiry = Math.floor(Date.now() / 1000) + parseInt(options.expiry);

  console.log("Creating intent...");
  console.log(`  Taker:        ${account.address}`);
  console.log(`  Input:        ${inputAmount} of ${inputToken}`);
  console.log(`  Output:       min ${minOutput} of ${outputToken}`);
  console.log(`  Dest chain:   ${destChainId}`);
  console.log(`  Dest address: ${destAddress}`);
  console.log(`  Expiry:       ${new Date(expiry * 1000).toISOString()}`);

  // 1. Approve escrow to spend input tokens
  console.log("\nApproving token spend...");
  const approveTx = await walletClient.writeContract({
    address: inputToken,
    abi: erc20Abi,
    functionName: "approve",
    args: [sourceChainConfig.escrowAddress, inputAmount],
  });
  console.log(`  Approve tx: ${approveTx}`);

  // 2. Create intent on-chain
  console.log("Creating intent on-chain...");
  const createTx = await walletClient.writeContract({
    address: sourceChainConfig.escrowAddress,
    abi: GauloiEscrowAbi,
    functionName: "createIntent",
    args: [
      inputToken,
      inputAmount,
      outputToken,
      minOutput,
      destChainId,
      destAddress,
      BigInt(expiry),
    ],
  });
  console.log(`  Create tx: ${createTx}`);

  // 3. Get the intent ID from the receipt
  const receipt = await publicClient.waitForTransactionReceipt({ hash: createTx });
  const intentCreatedLog = receipt.logs.find(
    (log) => log.topics[0] === "0x" // Will match IntentCreated event
  );

  // Parse intent ID from first indexed topic of IntentCreated event
  const intentId = receipt.logs[0]?.topics[1] as `0x${string}` | undefined;
  if (!intentId) {
    console.error("Failed to get intent ID from transaction receipt");
    process.exit(1);
  }

  console.log(`\nIntent created: ${intentId}`);

  // 4. Broadcast to relay and wait for quotes
  console.log("\nBroadcasting to relay, waiting for quotes...");

  const ws = new WebSocket(options.relay);

  ws.on("open", () => {
    ws.send(
      JSON.stringify({
        type: "intent_broadcast",
        data: {
          intentId,
          taker: account.address,
          inputToken,
          inputAmount: inputAmount.toString(),
          outputToken,
          destinationChainId: Number(destChainId),
          destinationAddress: destAddress,
          minOutputAmount: minOutput.toString(),
          expiry,
          sourceChainId: 1,
        },
      }),
    );
    console.log("Intent broadcast to relay.");
  });

  ws.on("message", (raw) => {
    const msg = JSON.parse(raw.toString());

    if (msg.type === "quote_received") {
      console.log(`\nQuote from ${msg.data.maker}:`);
      console.log(`  Output: ${msg.data.outputAmount}`);
      console.log(`  Est. fill: ${msg.data.estimatedFillTime}s`);
      console.log(`  Expires: ${new Date(msg.data.expiry * 1000).toISOString()}`);

      // Auto-select the first quote for simplicity
      console.log("\nAuto-selecting this quote...");
      ws.send(
        JSON.stringify({
          type: "quote_select",
          data: {
            intentId,
            maker: msg.data.maker,
          },
        }),
      );
    }

    if (msg.type === "error") {
      console.error(`Relay error: ${msg.data.message}`);
    }
  });

  ws.on("error", (err) => {
    console.error("WebSocket error:", err.message);
    process.exit(1);
  });

  // Keep alive for quote collection (timeout after expiry)
  setTimeout(() => {
    console.log("\nQuote collection timeout reached, closing.");
    ws.close();
  }, 120_000);
}
