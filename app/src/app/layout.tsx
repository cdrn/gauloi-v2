"use client";

import "./globals.css";
import "@rainbow-me/rainbowkit/styles.css";
import { WagmiProvider } from "wagmi";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { RainbowKitProvider, darkTheme } from "@rainbow-me/rainbowkit";
import { config } from "@/lib/wagmi";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import Link from "next/link";

const queryClient = new QueryClient();

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" className="dark">
      <body className="bg-gray-950 text-gray-100 min-h-screen">
        <WagmiProvider config={config}>
          <QueryClientProvider client={queryClient}>
            <RainbowKitProvider theme={darkTheme()}>
              <header className="border-b border-gray-800 px-6 py-4 flex items-center justify-between">
                <div className="flex items-center gap-8">
                  <Link href="/" className="text-xl font-bold tracking-tight">
                    gauloi
                  </Link>
                  <nav className="flex gap-4 text-sm text-gray-400">
                    <Link href="/" className="hover:text-white transition-colors">
                      Swap
                    </Link>
                    <Link href="/activity" className="hover:text-white transition-colors">
                      Activity
                    </Link>
                  </nav>
                </div>
                <ConnectButton />
              </header>
              <main className="max-w-lg mx-auto px-4 py-12">
                {children}
              </main>
            </RainbowKitProvider>
          </QueryClientProvider>
        </WagmiProvider>
      </body>
    </html>
  );
}
