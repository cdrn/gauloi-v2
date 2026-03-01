#!/usr/bin/env tsx
import { createPublicClient, http, formatUnits, formatEther } from "viem";
import { sepolia, arbitrumSepolia } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";

const key = process.env.PRIVATE_KEY as `0x${string}`;
if (!key) { console.error("PRIVATE_KEY required"); process.exit(1); }

const account = privateKeyToAccount(key);
console.log("Address:", account.address);

const sepoliaClient = createPublicClient({ chain: sepolia, transport: http("https://ethereum-sepolia-rpc.publicnode.com") });
const arbClient = createPublicClient({ chain: arbitrumSepolia, transport: http("https://arbitrum-sepolia-rpc.publicnode.com") });

const SEPOLIA_USDC = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238" as const;
const ARB_USDC = "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d" as const;
const abi = [{ type: "function", name: "balanceOf", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }], stateMutability: "view" }] as const;

async function main() {
  const [sepEth, arbEth, sepUsdc, arbUsdc] = await Promise.all([
    sepoliaClient.getBalance({ address: account.address }),
    arbClient.getBalance({ address: account.address }),
    sepoliaClient.readContract({ address: SEPOLIA_USDC, abi, functionName: "balanceOf", args: [account.address] }),
    arbClient.readContract({ address: ARB_USDC, abi, functionName: "balanceOf", args: [account.address] }),
  ]);

  console.log("Sepolia ETH:      ", formatEther(sepEth));
  console.log("Sepolia USDC:     ", formatUnits(sepUsdc, 6));
  console.log("Arb Sepolia ETH:  ", formatEther(arbEth));
  console.log("Arb Sepolia USDC: ", formatUnits(arbUsdc, 6));
}

main().catch(console.error);
