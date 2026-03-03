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
      <div className="pixel-border bg-navy-900 p-6 space-y-6">
        <h2 className="font-pixel text-sm text-pixel-cyan text-center">PAYMENT REQUEST</h2>

        <div className="text-center space-y-2">
          <p className="font-pixel text-lg text-pixel-cyan">{amount} {token}</p>
          <p className="text-sm text-teal-600">on {destChain?.name}</p>
          <p className="text-xs text-teal-600 font-mono">
            to {effectiveRecipient.slice(0, 6)}...{effectiveRecipient.slice(-4)}
          </p>
        </div>

        {/* QR Code */}
        <div className="flex justify-center">
          <div className="border-4 border-teal-600 p-3 bg-white">
            <QRCodeSVG
              value={url}
              size={200}
              level="M"
              includeMargin={false}
              fgColor="#0a0a2e"
              bgColor="#ffffff"
            />
          </div>
        </div>

        {/* URL + copy */}
        <div className="space-y-3">
          <div className="bg-navy-800 border-2 border-navy-600 p-3 text-[10px] font-mono text-teal-600 break-all">
            {url}
          </div>
          <button onClick={handleCopy} className="w-full pixel-btn">
            {copied ? "COPIED!" : "COPY LINK"}
          </button>
        </div>

        <button
          onClick={handleReset}
          className="w-full font-pixel text-[8px] text-teal-600 hover:text-teal-400 transition-colors py-1 uppercase"
        >
          Create new request
        </button>
      </div>
    );
  }

  return (
    <div className="pixel-border bg-navy-900 p-6 space-y-4">
      <h2 className="font-pixel text-sm text-pixel-cyan">REQUEST</h2>
      <p className="text-sm text-teal-600">
        Generate a QR code that anyone can scan to pay you.
      </p>

      {/* Dest chain */}
      <ChainSelector
        label="Receive on"
        value={destChainId}
        onChange={setDestChainId}
      />

      {/* Token + amount */}
      <div className="bg-navy-800 border-2 border-navy-600 p-4">
        <label className="font-pixel text-[8px] text-teal-600 uppercase block mb-2">Amount</label>
        <div className="flex gap-2 items-center">
          <input
            type="number"
            placeholder="0.00"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            className="flex-1 bg-transparent text-2xl font-bold outline-none placeholder-navy-600 text-pixel-cyan"
          />
          <TokenSelector value={token} onChange={setToken} />
        </div>
      </div>

      {/* Recipient */}
      <div>
        <label className="block font-pixel text-[8px] text-teal-600 uppercase tracking-widest mb-2">
          Recipient
        </label>
        <input
          type="text"
          placeholder={isConnected && address ? address : "0x..."}
          value={recipient}
          onChange={(e) => setRecipient(e.target.value)}
          className="w-full pixel-input text-xs"
        />
        {isConnected && !recipient && (
          <p className="font-pixel text-[7px] text-navy-600 mt-1">
            USING CONNECTED WALLET
          </p>
        )}
      </div>

      {!hasToken && destChainId && (
        <p className="font-pixel text-[8px] text-amber-400">
          {token} NOT AVAILABLE ON {destChain?.name?.toUpperCase() ?? "THIS CHAIN"}
        </p>
      )}

      {/* Generate */}
      <button
        onClick={handleGenerate}
        disabled={!canGenerate}
        className="w-full pixel-btn"
      >
        GENERATE QR
      </button>
    </div>
  );
}
