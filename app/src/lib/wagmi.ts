import { getDefaultConfig } from "@rainbow-me/rainbowkit";
import { sepolia, arbitrumSepolia, mainnet, arbitrum } from "wagmi/chains";
import { http } from "wagmi";
import { ENV } from "@/config/chains";

const isMainnet = ENV.label === "Mainnet";

export const config = getDefaultConfig({
  appName: "Gauloi",
  projectId: process.env.NEXT_PUBLIC_WC_PROJECT_ID ?? "demo",
  chains: isMainnet
    ? [mainnet, arbitrum]
    : [sepolia, arbitrumSepolia],
  transports: isMainnet
    ? {
        [mainnet.id]: http(process.env.NEXT_PUBLIC_ETHEREUM_RPC_URL),
        [arbitrum.id]: http(process.env.NEXT_PUBLIC_ARBITRUM_RPC_URL),
      }
    : {
        [sepolia.id]: http(process.env.NEXT_PUBLIC_SEPOLIA_RPC_URL ?? "https://ethereum-sepolia-rpc.publicnode.com"),
        [arbitrumSepolia.id]: http(process.env.NEXT_PUBLIC_ARB_SEPOLIA_RPC_URL ?? "https://arbitrum-sepolia-rpc.publicnode.com"),
      },
});
