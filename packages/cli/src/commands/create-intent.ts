import WebSocket from "ws";
import { randomBytes } from "crypto";
import { erc20Abi, keccak256, encodePacked, encodeAbiParameters } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import {
  GauloiEscrowAbi,
  getPublicClient,
  getWalletClient,
  SUPPORTED_CHAINS,
  signOrder,
  type OrderMessage,
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
  const expiry = BigInt(Math.floor(Date.now() / 1000) + parseInt(options.expiry));

  // Generate random nonce
  const nonce = BigInt("0x" + randomBytes(32).toString("hex"));

  console.log("Creating signed order...");
  console.log(`  Taker:        ${account.address}`);
  console.log(`  Input:        ${inputAmount} of ${inputToken}`);
  console.log(`  Output:       min ${minOutput} of ${outputToken}`);
  console.log(`  Dest chain:   ${destChainId}`);
  console.log(`  Dest address: ${destAddress}`);
  console.log(`  Expiry:       ${new Date(Number(expiry) * 1000).toISOString()}`);

  const order: OrderMessage = {
    taker: account.address,
    inputToken,
    inputAmount,
    outputToken,
    minOutputAmount: minOutput,
    destinationChainId: destChainId,
    destinationAddress: destAddress,
    expiry,
    nonce,
  };

  // 1. Check allowance and approve if needed
  const allowance = await publicClient.readContract({
    address: inputToken,
    abi: erc20Abi,
    functionName: "allowance",
    args: [account.address, sourceChainConfig.escrowAddress],
  });

  if (allowance < inputAmount) {
    console.log("\nApproving token spend...");
    const approveTx = await walletClient.writeContract({
      address: inputToken,
      abi: erc20Abi,
      functionName: "approve",
      args: [sourceChainConfig.escrowAddress, inputAmount],
    });
    console.log(`  Approve tx: ${approveTx}`);
    await publicClient.waitForTransactionReceipt({ hash: approveTx });
  } else {
    console.log("\nToken allowance sufficient, skipping approval.");
  }

  // 2. Sign order off-chain (0 gas!)
  console.log("Signing order (EIP-712)...");
  const takerSignature = await signOrder(
    walletClient,
    order,
    sourceChainConfig.escrowAddress,
    sourceChainConfig.chainId,
  );
  console.log(`  Signature: ${takerSignature.slice(0, 20)}...`);

  // 3. Compute intentId locally
  const intentId = keccak256(
    encodeAbiParameters(
      [
        { type: "address" },
        { type: "address" },
        { type: "uint256" },
        { type: "address" },
        { type: "uint256" },
        { type: "uint256" },
        { type: "address" },
        { type: "uint256" },
        { type: "uint256" },
      ],
      [
        account.address,
        inputToken,
        inputAmount,
        outputToken,
        minOutput,
        destChainId,
        destAddress,
        expiry,
        nonce,
      ],
    ),
  );

  console.log(`\nIntent ID: ${intentId}`);

  // 4. Broadcast signed order + signature to relay
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
          expiry: Number(expiry),
          nonce: nonce.toString(),
          takerSignature,
          sourceChainId: 1,
        },
      }),
    );
    console.log("Signed order broadcast to relay.");
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
