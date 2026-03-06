"use client";

import { useState, useEffect, useCallback } from "react";
import { useAccount, useReadContract, useSwitchChain } from "wagmi";
import { erc20Abi, formatUnits, parseUnits } from "viem";
import { SUPPORTED_CHAINS, SUPPORTED_TOKENS, IntentState } from "@gauloi/common";
import { ChainSelector } from "./ChainSelector";
import { TokenSelector } from "./TokenSelector";
import { QuoteList } from "./QuoteList";
import { useTokenAllowance } from "@/hooks/useTokenAllowance";
import { useSignOrder } from "@/hooks/useSignOrder";
import { useRelay } from "@/hooks/useRelay";
import { useIntentStatus } from "@/hooks/useIntentStatus";

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
  const [inputSymbol, setInputSymbol] = useState(initialParams?.token ?? "USDC");
  const [outputSymbol, setOutputSymbol] = useState(initialParams?.token ?? "USDC");
  const [amount, setAmount] = useState(initialParams?.amount ?? "");
  const [step, setStep] = useState<SwapStep>("form");
  const [currentIntentId, setCurrentIntentId] = useState<string | null>(null);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);

  const inputTokenInfo = SUPPORTED_TOKENS[inputSymbol];
  const outputTokenInfo = SUPPORTED_TOKENS[outputSymbol];
  const sourceChain = sourceChainId ? SUPPORTED_CHAINS[sourceChainId] : null;
  const destChain = destChainId ? SUPPORTED_CHAINS[destChainId] : null;

  const inputToken = inputTokenInfo?.addresses[sourceChainId ?? 0] as `0x${string}` | undefined;
  const outputToken = outputTokenInfo?.addresses[destChainId ?? 0] as `0x${string}` | undefined;

  const parsedAmount = amount
    ? parseUnits(amount, inputTokenInfo?.decimals ?? 6)
    : 0n;

  const minOutput = (parsedAmount * 9900n) / 10000n;
  const destinationAddress = initialParams?.recipient ?? address;

  useEffect(() => {
    if (walletChainId && !sourceChainId && SUPPORTED_CHAINS[walletChainId]) {
      setSourceChainId(walletChainId);
    }
  }, [walletChainId, sourceChainId]);

  const networkMismatch = isConnected && sourceChainId && walletChainId !== sourceChainId;

  const { data: balance } = useReadContract({
    address: inputToken,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: !!inputToken && !!address && !networkMismatch },
  });

  const {
    allowance,
    approve,
    isApproving,
    isConfirmed: approvalConfirmed,
    refetch: refetchAllowance,
  } = useTokenAllowance(inputToken, address, sourceChain?.escrowAddress);

  const { sign, isPending: isSigning } = useSignOrder();
  const relay = useRelay({ url: RELAY_URL });

  const { state: intentState, label: intentLabel } = useIntentStatus(
    currentIntentId as `0x${string}` | undefined,
    sourceChain?.escrowAddress as `0x${string}` | undefined,
  );

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
      relay.broadcast(result.intentId, result.order, result.signature, sourceChain.chainId);

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

  const formattedBalance = balance !== undefined && inputTokenInfo
    ? formatUnits(balance, inputTokenInfo.decimals)
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
    <div className="pixel-border bg-navy-900 p-6 space-y-4">
      {/* Header */}
      <div className="flex justify-between items-center">
        <h2 className="font-pixel text-sm text-pixel-cyan">
          {isPaymentRequest ? "PAY" : "SWAP"}
        </h2>
        {relay.connected && step === "quoting" && (
          <span className="font-pixel text-[8px] text-pixel-green flex items-center gap-2">
            <span className="w-2 h-2 bg-pixel-green inline-block" />
            RELAY OK
          </span>
        )}
      </div>

      {/* Payment request banner */}
      {isPaymentRequest && destChain && (
        <div className="border-2 border-amber-400 bg-navy-800 p-3">
          <p className="font-pixel text-[8px] text-amber-400 leading-relaxed">
            SEND {amount} {inputSymbol} TO{" "}
            <span className="text-pixel-cyan">{truncateAddress(initialParams!.recipient!)}</span>{" "}
            ON {destChain.name.toUpperCase()}
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
      <div className="bg-navy-800 border-2 border-navy-600 p-4">
        <div className="flex justify-between items-center mb-2">
          <label className="font-pixel text-[8px] text-teal-600 uppercase">You send</label>
          {formattedBalance !== null && (
            <button
              onClick={() => setAmount(formattedBalance)}
              className="font-pixel text-[8px] text-teal-600 hover:text-teal-400 transition-colors"
            >
              BAL: {Number(formattedBalance).toLocaleString()}
            </button>
          )}
        </div>
        <div className="flex gap-2 items-center">
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
            className={`flex-1 bg-transparent text-2xl font-bold outline-none placeholder-navy-600 text-pixel-cyan ${isPaymentRequest ? "opacity-60" : ""}`}
          />
          {isPaymentRequest ? (
            <span className="font-pixel text-[10px] text-pixel-cyan border-2 border-navy-600 px-3 py-2">
              {inputSymbol}
            </span>
          ) : (
            <TokenSelector value={inputSymbol} onChange={setInputSymbol} />
          )}
        </div>
        {insufficientBalance && (
          <p className="font-pixel text-[8px] text-pixel-red mt-2">INSUFFICIENT BALANCE</p>
        )}
      </div>

      {/* Arrow / swap button */}
      <div className="flex justify-center -my-1">
        {isPaymentRequest ? (
          <div className="font-pixel text-teal-600 text-lg">V</div>
        ) : (
          <button
            type="button"
            onClick={() => {
              const tmpChain = sourceChainId;
              setSourceChainId(destChainId);
              setDestChainId(tmpChain);
              const tmpToken = inputSymbol;
              setInputSymbol(outputSymbol);
              setOutputSymbol(tmpToken);
            }}
            className="font-pixel text-teal-600 text-lg hover:text-teal-400 transition-colors"
          >
            V
          </button>
        )}
      </div>

      {/* Dest chain */}
      {isPaymentRequest ? (
        <div>
          <label className="block font-pixel text-[8px] text-teal-600 uppercase tracking-widest mb-2">To</label>
          <div className="w-full pixel-input text-sm opacity-60">
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

      {/* Recipient for payment requests */}
      {isPaymentRequest && (
        <div>
          <label className="block font-pixel text-[8px] text-teal-600 uppercase tracking-widest mb-2">Recipient</label>
          <div className="w-full pixel-input text-xs opacity-60 break-all">
            {initialParams!.recipient}
          </div>
        </div>
      )}

      {/* Output preview */}
      {parsedAmount > 0n && step === "form" && (
        <div className="bg-navy-800 border-2 border-navy-600 p-4">
          <div className="flex justify-between items-center mb-2">
            <label className="font-pixel text-[8px] text-teal-600 uppercase">
              {isPaymentRequest ? "Recipient gets (min)" : "You receive (min)"}
            </label>
          </div>
          <div className="flex gap-2 items-center">
            <p className="flex-1 text-xl font-bold text-pixel-cyan">
              {formatUnits(minOutput, outputTokenInfo?.decimals ?? 6)}
            </p>
            {isPaymentRequest ? (
              <span className="font-pixel text-[10px] text-pixel-cyan border-2 border-navy-600 px-3 py-2">
                {outputSymbol}
              </span>
            ) : (
              <TokenSelector value={outputSymbol} onChange={setOutputSymbol} />
            )}
          </div>
          <p className="font-pixel text-[8px] text-teal-600 mt-1">1% MAX SLIPPAGE</p>
        </div>
      )}

      {/* Quotes */}
      {step === "quoting" && (
        <QuoteList
          quotes={relay.quotes}
          inputAmount={parsedAmount}
          decimals={outputTokenInfo?.decimals ?? 6}
          onSelect={handleSelectQuote}
        />
      )}

      {step === "accepted" && (
        <div className="bg-navy-800 border-2 border-navy-600 p-4 space-y-3">
          {/* Progress steps */}
          <div className="space-y-2">
            {[
              { state: null, label: "QUOTE ACCEPTED", done: true },
              { state: IntentState.Committed, label: "ORDER COMMITTED", done: intentState !== null && intentState >= IntentState.Committed },
              { state: IntentState.Filled, label: "FILLED ON DESTINATION", done: intentState !== null && intentState >= IntentState.Filled },
              { state: IntentState.Settled, label: "SETTLED", done: intentState === IntentState.Settled },
            ].map((s, i) => (
              <div key={i} className="flex items-center gap-2">
                <span className={`w-2 h-2 inline-block ${
                  s.done ? "bg-pixel-green" : "bg-navy-600"
                }`} />
                <span className={`font-pixel text-[8px] ${
                  s.done ? "text-pixel-green" : "text-teal-600"
                }`}>
                  {s.label}
                </span>
              </div>
            ))}
          </div>

          {/* Status message */}
          {intentState === IntentState.Disputed && (
            <p className="font-pixel text-[8px] text-pixel-red">FILL DISPUTED</p>
          )}
          {intentState === IntentState.Expired && (
            <p className="font-pixel text-[8px] text-pixel-red">ORDER EXPIRED</p>
          )}
          {intentState === IntentState.Settled && (
            <p className="font-pixel text-[8px] text-pixel-green">SWAP COMPLETE</p>
          )}
          {intentState !== null && intentState < IntentState.Settled && intentState !== IntentState.Disputed && intentState !== IntentState.Expired && (
            <p className="font-pixel text-[8px] text-teal-600 animate-pulse">PROCESSING...</p>
          )}
        </div>
      )}

      {/* Action button */}
      {networkMismatch && sourceChain ? (
        <button
          onClick={() => switchChain({ chainId: sourceChainId! })}
          className="w-full pixel-btn-amber"
        >
          Switch to {sourceChain.name}
        </button>
      ) : !isConnected ? (
        <div className="text-center font-pixel text-[10px] text-teal-600 py-3">
          CONNECT WALLET TO {isPaymentRequest ? "PAY" : "SWAP"}
        </div>
      ) : step === "accepted" ? (
        <button onClick={handleReset} className="w-full pixel-btn">
          {isPaymentRequest ? "DONE" : "NEW SWAP"}
        </button>
      ) : (
        <button
          onClick={handleSwap}
          disabled={!canSwap}
          className="w-full pixel-btn"
        >
          {step === "approving"
            ? "APPROVING..."
            : step === "signing"
              ? "SIGN IN WALLET..."
              : step === "quoting"
                ? "WAITING FOR QUOTES..."
                : insufficientBalance
                  ? "INSUFFICIENT BALANCE"
                  : needsApproval
                    ? `APPROVE ${inputSymbol}`
                    : isPaymentRequest
                      ? `PAY ${amount} ${inputSymbol}`
                      : "SWAP"}
        </button>
      )}

      {/* Error */}
      {(errorMsg || relay.error) && (
        <p className="font-pixel text-[8px] text-pixel-red text-center">
          {errorMsg || relay.error}
        </p>
      )}
    </div>
  );
}
