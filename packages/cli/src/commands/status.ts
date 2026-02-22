import { formatUnits } from "viem";
import {
  GauloiStakingAbi,
  getPublicClient,
  SUPPORTED_CHAINS,
} from "@gauloi/common";

interface StatusOptions {
  maker: string;
  rpc?: string;
  staking?: string;
}

export async function status(options: StatusOptions): Promise<void> {
  if (!options.rpc) {
    console.error("Error: --rpc or ETHEREUM_RPC_URL env var required");
    process.exit(1);
  }

  const chainConfig = {
    ...SUPPORTED_CHAINS[1]!,
    rpcUrl: options.rpc,
  };

  if (options.staking) {
    chainConfig.stakingAddress = options.staking as `0x${string}`;
  }

  const publicClient = getPublicClient(chainConfig);
  const makerAddress = options.maker as `0x${string}`;

  console.log(`Maker status: ${makerAddress}\n`);

  try {
    const makerInfo = await publicClient.readContract({
      address: chainConfig.stakingAddress,
      abi: GauloiStakingAbi,
      functionName: "getMakerInfo",
      args: [makerAddress],
    }) as any;

    const stakedAmount = BigInt(makerInfo.stakedAmount ?? makerInfo[0]);
    const activeExposure = BigInt(makerInfo.activeExposure ?? makerInfo[1]);
    const unstakeRequestTime = BigInt(makerInfo.unstakeRequestTime ?? makerInfo[2]);
    const unstakeAmount = BigInt(makerInfo.unstakeAmount ?? makerInfo[3]);
    const isActive = makerInfo.isActive ?? makerInfo[4];

    console.log(`  Active:           ${isActive}`);
    console.log(`  Staked:           ${formatUnits(stakedAmount, 6)} USDC`);
    console.log(`  Active exposure:  ${formatUnits(activeExposure, 6)} USDC`);

    const capacity = stakedAmount - activeExposure;
    console.log(`  Available:        ${formatUnits(capacity, 6)} USDC`);

    if (unstakeRequestTime > 0n) {
      const readyAt = new Date(Number(unstakeRequestTime) * 1000);
      console.log(`\n  Unstake pending:  ${formatUnits(unstakeAmount, 6)} USDC`);
      console.log(`  Ready at:         ${readyAt.toISOString()}`);

      if (readyAt.getTime() < Date.now()) {
        console.log(`  Status:           Ready to complete`);
      } else {
        const remaining = Math.ceil((readyAt.getTime() - Date.now()) / 1000);
        console.log(`  Status:           ${remaining}s remaining`);
      }
    }
  } catch (err: any) {
    console.error(`Failed to read staking info: ${err.message}`);
    process.exit(1);
  }
}
