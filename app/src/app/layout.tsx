import "./globals.css";
import "@rainbow-me/rainbowkit/styles.css";
import type { Metadata } from "next";
import { Providers } from "@/components/Providers";
import { Header } from "@/components/Header";

export const metadata: Metadata = {
  title: "Gauloi — Cross-Chain Stablecoin Swaps",
  description: "Swap stablecoins across chains with zero gas for takers. Intent-based settlement with competitive maker quotes.",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" className="dark">
      <body className="bg-gray-950 text-gray-100 min-h-screen">
        <Providers>
          <Header />
          <main className="max-w-lg mx-auto px-4 py-12">
            {children}
          </main>
        </Providers>
      </body>
    </html>
  );
}
