"use client";

import { useState, useEffect, useCallback } from "react";
import { useAccount, useReadContract, useSwitchChain } from "wagmi";
import { erc20Abi, formatUnits, parseUnits } from "viem";
import { SUPPORTED_CHAINS, SUPPORTED_TOKENS } from "@gauloi/common";
import { ChainSelector } from "./ChainSelector";
import { TokenSelector } from "./TokenSelector";
import { QuoteList } from "./QuoteList";
import { useTokenAllowance } from "@/hooks/useTokenAllowance";
import { useSignOrder } from "@/hooks/useSignOrder";
import { useRelay } from "@/hooks/useRelay";

type SwapStep = "form" | "approving" | "signing" | "quoting" | "accepted";

const RELAY_URL = process.env.NEXT_PUBLIC_RELAY_URL ?? "ws://127.0.0.1:8080";

export interface SwapInitialParams {
  destChainId?: number;
  token?: string;
  amount?: string;
  recipient?: `0x${string}`;
}

interface SwapFormProps {
  initialParams?: SwapInitialParams;
}

function truncateAddress(addr: string): string {
  return `${addr.slice(0, 6)}...${addr.slice(-4)}`;
}

export function SwapForm({ initialParams }: SwapFormProps) {
  const { address, isConnected, chainId: walletChainId } = useAccount();
  const { switchChain } = useSwitchChain();

  const isPaymentRequest = !!initialParams?.recipient;

  const [sourceChainId, setSourceChainId] = useState<number | null>(null);
  const [destChainId, setDestChainId] = useState<number | null>(initialParams?.destChainId ?? null);
  const [token, setToken] = useState(initialParams?.token ?? "USDC");
  const [amount, setAmount] = useState(initialParams?.amount ?? "");
  const [step, setStep] = useState<SwapStep>("form");
  const [currentIntentId, setCurrentIntentId] = useState<string | null>(null);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);

  const tokenInfo = SUPPORTED_TOKENS[token];
  const sourceChain = sourceChainId ? SUPPORTED_CHAINS[sourceChainId] : null;
  const destChain = destChainId ? SUPPORTED_CHAINS[destChainId] : null;

  const inputToken = tokenInfo?.addresses[sourceChainId ?? 0] as `0x${string}` | undefined;
  const outputToken = tokenInfo?.addresses[destChainId ?? 0] as `0x${string}` | undefined;

  const parsedAmount = amount
    ? parseUnits(amount, tokenInfo?.decimals ?? 6)
    : 0n;

  // Min output: input minus 100 bps (1%) as default slippage tolerance
  const minOutput = (parsedAmount * 9900n) / 10000n;

  // The address that receives funds on the dest chain
  const destinationAddress = initialParams?.recipient ?? address;

  // Auto-set source chain from wallet
  useEffect(() => {
    if (walletChainId && !sourceChainId && SUPPORTED_CHAINS[walletChainId]) {
      setSourceChainId(walletChainId);
    }
  }, [walletChainId, sourceChainId]);

  // Network mismatch detection
  const networkMismatch = isConnected && sourceChainId && walletChainId !== sourceChainId;

  // Read user's token balance
  const { data: balance } = useReadContract({
    address: inputToken,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: !!inputToken && !!address && !networkMismatch },
  });

  // Allowance hook
  const {
    allowance,
    approve,
    isApproving,
    isConfirmed: approvalConfirmed,
    refetch: refetchAllowance,
  } = useTokenAllowance(inputToken, address, sourceChain?.escrowAddress);

  // Sign hook
  const { sign, isPending: isSigning } = useSignOrder();

  // Relay hook
  const relay = useRelay({ url: RELAY_URL, enabled: step === "quoting" || step === "accepted" });

  const handleSign = useCallback(async () => {
    if (!address || !sourceChain || !destChain || !inputToken || !outputToken || !destinationAddress) return;
    setStep("signing");
    setErrorMsg(null);

    try {
      const result = await sign({
        taker: address,
        inputToken,
        inputAmount: parsedAmount,
        outputToken,
        minOutputAmount: minOutput,
        destinationChainId: destChain.chainId,
        destinationAddress: destinationAddress,
        expirySeconds: 600,
        escrowAddress: sourceChain.escrowAddress,
        chainId: sourceChain.chainId,
      });

      setCurrentIntentId(result.intentId);
      setStep("quoting");

      // Broadcast to relay
      relay.broadcast(result.intentId, result.order, result.signature, sourceChain.chainId);

      // Store in localStorage for activity page
      const stored = JSON.parse(localStorage.getItem("gauloi_intents") ?? "[]");
      stored.unshift({
        intentId: result.intentId,
        inputAmount: parsedAmount.toString(),
        sourceChainId: sourceChain.chainId,
        destChainId: destChain.chainId,
        timestamp: Date.now(),
      });
      localStorage.setItem("gauloi_intents", JSON.stringify(stored.slice(0, 50)));
    } catch (err) {
      const message = err instanceof Error ? err.message : "Signing failed";
      if (message.includes("User rejected")) {
        setErrorMsg("Transaction rejected in wallet");
      } else {
        setErrorMsg(message);
      }
      setStep("form");
    }
  }, [address, sourceChain, destChain, inputToken, outputToken, destinationAddress, parsedAmount, minOutput, sign, relay]);

  // After approval confirms, proceed to signing
  useEffect(() => {
    if (approvalConfirmed && step === "approving") {
      refetchAllowance();
      handleSign();
    }
  }, [approvalConfirmed, step, refetchAllowance, handleSign]);

  const needsApproval = parsedAmount > 0n && allowance < parsedAmount;

  const handleSwap = async () => {
    setErrorMsg(null);
    if (needsApproval) {
      setStep("approving");
      approve(parsedAmount);
    } else {
      await handleSign();
    }
  };

  const handleSelectQuote = (maker: string) => {
    if (!currentIntentId) return;
    relay.selectQuote(currentIntentId, maker);
    setStep("accepted");
  };

  const handleReset = () => {
    setStep("form");
    setAmount(initialParams?.amount ?? "");
    setCurrentIntentId(null);
    setErrorMsg(null);
  };

  // Auto-select best quote after 5s
  useEffect(() => {
    if (step !== "quoting" || relay.quotes.length === 0) return;

    const timer = setTimeout(() => {
      const best = [...relay.quotes].sort(
        (a, b) => Number(BigInt(b.outputAmount) - BigInt(a.outputAmount)),
      )[0];
      if (best) handleSelectQuote(best.maker);
    }, 5000);

    return () => clearTimeout(timer);
  }, [step, relay.quotes]);

  const formattedBalance = balance !== undefined && tokenInfo
    ? formatUnits(balance, tokenInfo.decimals)
    : null;

  const insufficientBalance = balance !== undefined && parsedAmount > 0n && parsedAmount > balance;

  const canSwap =
    isConnected &&
    sourceChainId &&
    destChainId &&
    inputToken &&
    outputToken &&
    parsedAmount > 0n &&
    !insufficientBalance &&
    !networkMismatch &&
    step === "form";

  return (
    <div className="bg-gray-900 border border-gray-800 rounded-2xl p-6 space-y-4">
      <div className="flex justify-between items-center">
        <h2 className="text-lg font-semibold">
          {isPaymentRequest ? "Payment Request" : "Swap"}
        </h2>
        {relay.connected && step === "quoting" && (
          <span className="text-xs text-green-400 flex items-center gap-1">
            <span className="w-1.5 h-1.5 rounded-full bg-green-400 inline-block" />
            Relay connected
          </span>
        )}
      </div>

      {/* Payment request banner */}
      {isPaymentRequest && destChain && (
        <div className="bg-blue-900/30 border border-blue-800 rounded-xl p-3">
          <p className="text-sm text-blue-300">
            Send <span className="font-medium">{amount} {token}</span> to{" "}
            <span className="font-mono text-xs">{truncateAddress(initialParams!.recipient!)}</span>{" "}
            on {destChain.name}
          </p>
        </div>
      )}

      {/* Source chain */}
      <ChainSelector
        label="From"
        value={sourceChainId}
        onChange={setSourceChainId}
        exclude={destChainId}
      />

      {/* Input amount + token */}
      <div className="bg-gray-800 rounded-xl p-4">
        <div className="flex justify-between items-center mb-2">
          <label className="text-xs text-gray-500">You send</label>
          {formattedBalance !== null && (
            <button
              onClick={() => setAmount(formattedBalance)}
              className="text-xs text-gray-500 hover:text-white"
            >
              Balance: {Number(formattedBalance).toLocaleString()}
            </button>
          )}
        </div>
        <div className="flex gap-2">
          <input
            type="number"
            placeholder="0.00"
            value={amount}
            onChange={(e) => {
              setAmount(e.target.value);
              setStep("form");
              setErrorMsg(null);
            }}
            readOnly={isPaymentRequest}
            className={`flex-1 bg-transparent text-2xl font-medium outline-none placeholder-gray-600 [appearance:textfield] [&::-webkit-outer-spin-button]:appearance-none [&::-webkit-inner-spin-button]:appearance-none ${isPaymentRequest ? "text-gray-400" : ""}`}
          />
          {isPaymentRequest ? (
            <span className="bg-gray-700 border border-gray-600 rounded-lg px-3 py-2 text-sm font-medium">
              {token}
            </span>
          ) : (
            <TokenSelector value={token} onChange={setToken} />
          )}
        </div>
        {insufficientBalance && (
          <p className="text-xs text-red-400 mt-2">Insufficient balance</p>
        )}
      </div>

      {/* Arrow */}
      <div className="flex justify-center -my-2">
        <div className="bg-gray-800 border border-gray-700 rounded-lg p-1.5">
          <svg className="w-4 h-4 text-gray-400" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 14l-7 7m0 0l-7-7m7 7V3" />
          </svg>
        </div>
      </div>

      {/* Dest chain */}
      {isPaymentRequest ? (
        <div>
          <label className="block text-xs text-gray-500 mb-1">To</label>
          <div className="w-full bg-gray-800 border border-gray-700 rounded-lg px-3 py-2 text-sm text-gray-400">
            {destChain?.name ?? "Unknown chain"}
          </div>
        </div>
      ) : (
        <ChainSelector
          label="To"
          value={destChainId}
          onChange={setDestChainId}
          exclude={sourceChainId}
        />
      )}

      {/* Recipient display for payment requests */}
      {isPaymentRequest && (
        <div>
          <label className="block text-xs text-gray-500 mb-1">Recipient</label>
          <div className="w-full bg-gray-800 border border-gray-700 rounded-lg px-3 py-2 text-sm font-mono text-gray-400">
            {initialParams!.recipient}
          </div>
        </div>
      )}

      {/* Output preview */}
      {parsedAmount > 0n && step === "form" && (
        <div className="bg-gray-800 rounded-xl p-4">
          <label className="text-xs text-gray-500 block mb-2">
            {isPaymentRequest ? "Recipient gets (minimum)" : "You receive (minimum)"}
          </label>
          <p className="text-2xl font-medium">
            {formatUnits(minOutput, tokenInfo?.decimals ?? 6)} {token}
          </p>
          <p className="text-xs text-gray-500 mt-1">1% max slippage</p>
        </div>
      )}

      {/* Quotes */}
      {step === "quoting" && (
        <QuoteList
          quotes={relay.quotes}
          inputAmount={parsedAmount}
          decimals={tokenInfo?.decimals ?? 6}
          onSelect={handleSelectQuote}
        />
      )}

      {step === "accepted" && (
        <div className="bg-green-900/30 border border-green-800 rounded-xl p-4 text-center">
          <p className="text-green-300 text-sm font-medium">Quote accepted</p>
          <p className="text-xs text-gray-400 mt-1">
            {isPaymentRequest
              ? "Maker is executing the payment. Track progress in Activity."
              : "Maker is executing your order. Track progress in Activity."}
          </p>
        </div>
      )}

      {/* Network switch prompt */}
      {networkMismatch && sourceChain ? (
        <button
          onClick={() => switchChain({ chainId: sourceChainId! })}
          className="w-full bg-yellow-600 text-white font-medium py-3 rounded-xl hover:bg-yellow-500 transition-colors"
        >
          Switch to {sourceChain.name}
        </button>
      ) : !isConnected ? (
        <div className="text-center text-sm text-gray-500 py-2">
          Connect your wallet to {isPaymentRequest ? "pay" : "swap"}
        </div>
      ) : step === "accepted" ? (
        <button
          onClick={handleReset}
          className="w-full bg-gray-800 text-white font-medium py-3 rounded-xl hover:bg-gray-700 transition-colors"
        >
          {isPaymentRequest ? "Done" : "New Swap"}
        </button>
      ) : (
        <button
          onClick={handleSwap}
          disabled={!canSwap}
          className="w-full bg-white text-black font-medium py-3 rounded-xl hover:bg-gray-200 transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
        >
          {step === "approving"
            ? "Approving..."
            : step === "signing"
              ? "Sign order in wallet..."
              : step === "quoting"
                ? "Waiting for quotes..."
                : insufficientBalance
                  ? "Insufficient balance"
                  : needsApproval
                    ? `Approve ${token}`
                    : isPaymentRequest
                      ? `Pay ${amount} ${token}`
                      : "Swap"}
        </button>
      )}

      {/* Error display */}
      {(errorMsg || relay.error) && (
        <p className="text-xs text-red-400 text-center">
          {errorMsg || relay.error}
        </p>
      )}
    </div>
  );
}
