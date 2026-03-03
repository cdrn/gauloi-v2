"use client";

import { useState } from "react";
import { useAccount } from "wagmi";
import { QRCodeSVG } from "qrcode.react";
import { SUPPORTED_CHAINS, SUPPORTED_TOKENS } from "@gauloi/common";
import { ChainSelector } from "./ChainSelector";
import { TokenSelector } from "./TokenSelector";

export function PaymentRequest() {
  const { address, isConnected } = useAccount();

  const [destChainId, setDestChainId] = useState<number | null>(null);
  const [token, setToken] = useState("USDC");
  const [amount, setAmount] = useState("");
  const [recipient, setRecipient] = useState("");
  const [generated, setGenerated] = useState(false);
  const [copied, setCopied] = useState(false);

  // Auto-fill recipient from connected wallet
  const effectiveRecipient = recipient || address || "";

  const destChain = destChainId ? SUPPORTED_CHAINS[destChainId] : null;
  const tokenInfo = SUPPORTED_TOKENS[token];
  const hasToken = destChainId ? !!tokenInfo?.addresses[destChainId] : false;

  const canGenerate =
    destChainId &&
    amount &&
    parseFloat(amount) > 0 &&
    effectiveRecipient.startsWith("0x") &&
    effectiveRecipient.length === 42 &&
    hasToken;

  const buildUrl = () => {
    const base = typeof window !== "undefined" ? window.location.origin : "";
    const params = new URLSearchParams();
    params.set("to", String(destChainId));
    params.set("token", token);
    params.set("amount", amount);
    params.set("recipient", effectiveRecipient);
    return `${base}/?${params.toString()}`;
  };

  const handleGenerate = () => {
    setGenerated(true);
    setCopied(false);
  };

  const handleCopy = async () => {
    await navigator.clipboard.writeText(buildUrl());
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  const handleReset = () => {
    setGenerated(false);
    setAmount("");
    setCopied(false);
  };

  if (generated && canGenerate) {
    const url = buildUrl();
    return (
      <div className="bg-gray-900 border border-gray-800 rounded-2xl p-6 space-y-6">
        <h2 className="text-lg font-semibold text-center">Payment Request</h2>

        <div className="text-center space-y-1">
          <p className="text-2xl font-medium">{amount} {token}</p>
          <p className="text-sm text-gray-400">on {destChain?.name}</p>
          <p className="text-xs text-gray-500 font-mono">
            to {effectiveRecipient.slice(0, 6)}...{effectiveRecipient.slice(-4)}
          </p>
        </div>

        {/* QR Code */}
        <div className="flex justify-center">
          <div className="bg-white p-4 rounded-xl">
            <QRCodeSVG
              value={url}
              size={200}
              level="M"
              includeMargin={false}
            />
          </div>
        </div>

        {/* URL + copy */}
        <div className="space-y-2">
          <div className="bg-gray-800 rounded-lg p-3 text-xs font-mono text-gray-400 break-all">
            {url}
          </div>
          <button
            onClick={handleCopy}
            className="w-full bg-gray-800 text-white font-medium py-2.5 rounded-xl hover:bg-gray-700 transition-colors text-sm"
          >
            {copied ? "Copied!" : "Copy Link"}
          </button>
        </div>

        <button
          onClick={handleReset}
          className="w-full text-sm text-gray-500 hover:text-white transition-colors py-1"
        >
          Create new request
        </button>
      </div>
    );
  }

  return (
    <div className="bg-gray-900 border border-gray-800 rounded-2xl p-6 space-y-4">
      <h2 className="text-lg font-semibold">Request Payment</h2>
      <p className="text-sm text-gray-500">
        Generate a QR code that anyone can scan to pay you.
      </p>

      {/* Dest chain (where you want to receive) */}
      <ChainSelector
        label="Receive on"
        value={destChainId}
        onChange={setDestChainId}
      />

      {/* Token + amount */}
      <div className="bg-gray-800 rounded-xl p-4">
        <label className="text-xs text-gray-500 block mb-2">Amount</label>
        <div className="flex gap-2">
          <input
            type="number"
            placeholder="0.00"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            className="flex-1 bg-transparent text-2xl font-medium outline-none placeholder-gray-600 [appearance:textfield] [&::-webkit-outer-spin-button]:appearance-none [&::-webkit-inner-spin-button]:appearance-none"
          />
          <TokenSelector value={token} onChange={setToken} />
        </div>
      </div>

      {/* Recipient address */}
      <div>
        <label className="block text-xs text-gray-500 mb-1">
          Recipient address
        </label>
        <input
          type="text"
          placeholder={isConnected && address ? address : "0x..."}
          value={recipient}
          onChange={(e) => setRecipient(e.target.value)}
          className="w-full bg-gray-800 border border-gray-700 rounded-lg px-3 py-2 text-sm font-mono focus:outline-none focus:border-gray-500 placeholder-gray-600"
        />
        {isConnected && !recipient && (
          <p className="text-xs text-gray-600 mt-1">
            Using connected wallet address
          </p>
        )}
      </div>

      {!hasToken && destChainId && (
        <p className="text-xs text-yellow-400">
          {token} not available on {destChain?.name ?? "this chain"}
        </p>
      )}

      {/* Generate button */}
      <button
        onClick={handleGenerate}
        disabled={!canGenerate}
        className="w-full bg-white text-black font-medium py-3 rounded-xl hover:bg-gray-200 transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
      >
        Generate QR Code
      </button>
    </div>
  );
}
