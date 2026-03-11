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
  bidirectional?: boolean;
  disputeOnly?: boolean;
  disputePollInterval: string;
}

function buildBot(
  privateKey: `0x${string}`,
  sourceChainId: number,
  destChainId: number,
  options: RunMakerOptions,
): MakerBot {
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

  if (options.escrow) sourceChain.escrowAddress = options.escrow as `0x${string}`;
  if (options.staking) sourceChain.stakingAddress = options.staking as `0x${string}`;
  if (options.disputes) sourceChain.disputesAddress = options.disputes as `0x${string}`;

  if (!sourceChain.rpcUrl || !destChain.rpcUrl) {
    console.error("Error: RPC URLs required (--source-rpc / --dest-rpc or env vars)");
    process.exit(1);
  }

  const account = privateKeyToAccount(privateKey);

  console.log(`  [${sourceChain.name} → ${destChain.name}]`);
  console.log(`    Escrow:  ${sourceChain.escrowAddress}`);

  return new MakerBot({
    makerAddress: account.address,
    relayUrl: options.relay,
    sourceChain,
    destChain,
    sourcePublicClient: getPublicClient(sourceChain),
    sourceWalletClient: getWalletClient(sourceChain, privateKey) as any,
    destPublicClient: getPublicClient(destChain),
    destWalletClient: getWalletClient(destChain, privateKey) as any,
    quoterConfig: {
      spreads: {
        clean: parseInt(options.spreadClean),
        unknown: parseInt(options.spreadUnknown),
      },
      maxFillSize: BigInt(options.maxFill) * 10n ** 6n,
    },
    settleIntervalMs: parseInt(options.settleInterval),
    disputePollIntervalMs: parseInt(options.disputePollInterval),
    disputeOnly: options.disputeOnly,
  });
}

export async function runMaker(options: RunMakerOptions): Promise<void> {
  if (!options.privateKey) {
    console.error("Error: --private-key or PRIVATE_KEY env var required");
    process.exit(1);
  }

  const privateKey = options.privateKey as `0x${string}`;
  const account = privateKeyToAccount(privateKey);
  const sourceChainId = parseInt(options.sourceChain);
  const destChainId = parseInt(options.destChain);

  const mode = options.disputeOnly ? "dispute-only" : "full";
  console.log(`Starting maker bot (${mode} mode)...`);
  console.log(`  Maker:        ${account.address}`);
  if (!options.disputeOnly) {
    console.log(`  Relay:        ${options.relay}`);
    console.log(`  Spread:       ${options.spreadClean} bps (clean), ${options.spreadUnknown} bps (unknown)`);
    console.log(`  Max fill:     ${options.maxFill} USDC`);
    console.log(`  Settle every: ${options.settleInterval}ms`);
  }

  const bots: MakerBot[] = [];

  bots.push(buildBot(privateKey, sourceChainId, destChainId, options));

  if (options.bidirectional) {
    // Swap source/dest RPCs for the reverse direction
    const reverseOptions = {
      ...options,
      sourceRpc: options.destRpc,
      destRpc: options.sourceRpc,
    };
    bots.push(buildBot(privateKey, destChainId, sourceChainId, reverseOptions));
  }

  await Promise.all(bots.map((b) => b.start()));

  const shutdown = () => {
    console.log("\nShutting down...");
    bots.forEach((b) => b.stop());
    process.exit(0);
  };

  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);

  // Keep the process alive
  await new Promise(() => {});
}
