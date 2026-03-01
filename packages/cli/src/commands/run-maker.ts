import { privateKeyToAccount } from "viem/accounts";
import {
  type ChainConfig,
  SUPPORTED_CHAINS,
  getPublicClient,
  getWalletClient,
} from "@gauloi/common";
import { MakerBot } from "@gauloi/maker";

interface RunMakerOptions {
  privateKey?: string;
  sourceRpc?: string;
  destRpc?: string;
  sourceChain: string;
  destChain: string;
  escrow?: string;
  staking?: string;
  disputes?: string;
  relay: string;
  settleInterval: string;
  spreadClean: string;
  spreadUnknown: string;
  maxFill: string;
}

export async function runMaker(options: RunMakerOptions): Promise<void> {
  if (!options.privateKey) {
    console.error("Error: --private-key or PRIVATE_KEY env var required");
    process.exit(1);
  }

  const account = privateKeyToAccount(options.privateKey as `0x${string}`);
  const sourceChainId = parseInt(options.sourceChain);
  const destChainId = parseInt(options.destChain);

  // Build chain configs
  const sourceBase = SUPPORTED_CHAINS[sourceChainId];
  const destBase = SUPPORTED_CHAINS[destChainId];

  if (!sourceBase || !destBase) {
    console.error(`Unsupported chain ID. Supported: ${Object.keys(SUPPORTED_CHAINS).join(", ")}`);
    process.exit(1);
  }

  const sourceChain: ChainConfig = {
    ...sourceBase,
    rpcUrl: options.sourceRpc ?? sourceBase.rpcUrl,
  };

  const destChain: ChainConfig = {
    ...destBase,
    rpcUrl: options.destRpc ?? destBase.rpcUrl,
  };

  // Override contract addresses if provided
  if (options.escrow) sourceChain.escrowAddress = options.escrow as `0x${string}`;
  if (options.staking) sourceChain.stakingAddress = options.staking as `0x${string}`;
  if (options.disputes) sourceChain.disputesAddress = options.disputes as `0x${string}`;

  if (!sourceChain.rpcUrl || !destChain.rpcUrl) {
    console.error("Error: RPC URLs required (--source-rpc / --dest-rpc or env vars)");
    process.exit(1);
  }

  const sourcePublicClient = getPublicClient(sourceChain);
  const destPublicClient = getPublicClient(destChain);
  const sourceWalletClient = getWalletClient(sourceChain, options.privateKey as `0x${string}`);
  const destWalletClient = getWalletClient(destChain, options.privateKey as `0x${string}`);

  console.log("Starting maker bot...");
  console.log(`  Maker:        ${account.address}`);
  console.log(`  Source chain:  ${sourceChain.name} (${sourceChainId})`);
  console.log(`  Dest chain:    ${destChain.name} (${destChainId})`);
  console.log(`  Relay:         ${options.relay}`);
  console.log(`  Escrow:        ${sourceChain.escrowAddress}`);
  console.log(`  Spread:        ${options.spreadClean} bps (clean), ${options.spreadUnknown} bps (unknown)`);
  console.log(`  Max fill:      ${options.maxFill} USDC`);
  console.log(`  Settle every:  ${options.settleInterval}ms`);

  const bot = new MakerBot({
    makerAddress: account.address,
    relayUrl: options.relay,
    sourceChain,
    destChain,
    sourcePublicClient,
    sourceWalletClient: sourceWalletClient as any,
    destPublicClient,
    destWalletClient: destWalletClient as any,
    quoterConfig: {
      spreads: {
        clean: parseInt(options.spreadClean),
        unknown: parseInt(options.spreadUnknown),
      },
      maxFillSize: BigInt(options.maxFill) * 10n ** 6n,
    },
    settleIntervalMs: parseInt(options.settleInterval),
  });

  await bot.start();

  // Keep alive until SIGINT
  process.on("SIGINT", () => {
    console.log("\nShutting down...");
    bot.stop();
    process.exit(0);
  });

  process.on("SIGTERM", () => {
    bot.stop();
    process.exit(0);
  });

  // Keep the process alive
  await new Promise(() => {});
}
