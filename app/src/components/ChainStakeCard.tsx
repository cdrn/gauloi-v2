"use client";

import { useState, useEffect, useRef } from "react";
import {
  useReadContract,
  useWriteContract,
  useWaitForTransactionReceipt,
  useAccount,
  useSwitchChain,
} from "wagmi";
import { erc20Abi, formatUnits, parseUnits } from "viem";
import { GauloiStakingAbi, type ChainConfig } from "@gauloi/common";
import { ChainIcon } from "./icons";

const POLL_INTERVAL = 10_000;

interface ChainStakeCardProps {
  chain: ChainConfig;
  maker: `0x${string}`;
}

export function ChainStakeCard({ chain, maker }: ChainStakeCardProps) {
  const { chainId: walletChainId } = useAccount();
  const { switchChain } = useSwitchChain();
  const [stakeAmount, setStakeAmount] = useState("");
  const [unstakeAmount, setUnstakeAmount] = useState("");
  const [action, setAction] = useState<"idle" | "approving" | "staking" | "requesting_unstake" | "completing_unstake">("idle");
  const pendingStakeRef = useRef("");

  const wrongChain = walletChainId !== chain.chainId;

  // Read staking state (polls every 10s)
  const { data: makerInfo, refetch: refetchMakerInfo } = useReadContract({
    address: chain.stakingAddress as `0x${string}`,
    abi: GauloiStakingAbi,
    functionName: "getMakerInfo",
    args: [maker],
    chainId: chain.chainId,
    query: { refetchInterval: POLL_INTERVAL },
  });

  const { data: stakeTokenAddr } = useReadContract({
    address: chain.stakingAddress as `0x${string}`,
    abi: GauloiStakingAbi,
    functionName: "stakeToken",
    chainId: chain.chainId,
  });

  const { data: minStakeRaw } = useReadContract({
    address: chain.stakingAddress as `0x${string}`,
    abi: GauloiStakingAbi,
    functionName: "minStake",
    chainId: chain.chainId,
  });

  const { data: cooldownRaw } = useReadContract({
    address: chain.stakingAddress as `0x${string}`,
    abi: GauloiStakingAbi,
    functionName: "cooldownPeriod",
    chainId: chain.chainId,
  });

  // Read wallet USDC balance
  const { data: walletBalance, refetch: refetchBalance } = useReadContract({
    address: stakeTokenAddr as `0x${string}`,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [maker],
    chainId: chain.chainId,
    query: { enabled: !!stakeTokenAddr, refetchInterval: POLL_INTERVAL },
  });

  // Read current allowance
  const { data: allowance, refetch: refetchAllowance } = useReadContract({
    address: stakeTokenAddr as `0x${string}`,
    abi: erc20Abi,
    functionName: "allowance",
    args: [maker, chain.stakingAddress as `0x${string}`],
    chainId: chain.chainId,
    query: { enabled: !!stakeTokenAddr },
  });

  // Write contract
  const { writeContract, data: txHash, reset: resetTx } = useWriteContract();
  const { isSuccess: txConfirmed } = useWaitForTransactionReceipt({ hash: txHash });

  // Handle tx confirmation
  useEffect(() => {
    if (!txConfirmed) return;

    if (action === "approving") {
      // Approval done, now stake
      const parsed = parseUnits(pendingStakeRef.current, 6);
      resetTx();
      setTimeout(() => {
        setAction("staking");
        writeContract({
          address: chain.stakingAddress as `0x${string}`,
          abi: GauloiStakingAbi,
          functionName: "stake",
          args: [parsed],
        });
      }, 100);
      return;
    }

    // Any other action completed — refetch after a short delay for chain finality
    resetTx();
    setAction("idle");
    setStakeAmount("");
    setUnstakeAmount("");
    setTimeout(() => {
      refetchMakerInfo();
      refetchBalance();
      refetchAllowance();
    }, 2000);
  }, [txConfirmed, action]);

  const handleStake = () => {
    if (!stakeAmount || wrongChain) return;
    const parsed = parseUnits(stakeAmount, 6);
    pendingStakeRef.current = stakeAmount;

    const currentAllowance = allowance ?? 0n;
    if (currentAllowance < parsed) {
      setAction("approving");
      writeContract({
        address: stakeTokenAddr as `0x${string}`,
        abi: erc20Abi,
        functionName: "approve",
        args: [chain.stakingAddress as `0x${string}`, parsed],
      });
    } else {
      setAction("staking");
      writeContract({
        address: chain.stakingAddress as `0x${string}`,
        abi: GauloiStakingAbi,
        functionName: "stake",
        args: [parsed],
      });
    }
  };

  const handleRequestUnstake = () => {
    if (!unstakeAmount || wrongChain) return;
    const parsed = parseUnits(unstakeAmount, 6);
    setAction("requesting_unstake");
    writeContract({
      address: chain.stakingAddress as `0x${string}`,
      abi: GauloiStakingAbi,
      functionName: "requestUnstake",
      args: [parsed],
    });
  };

  const handleCompleteUnstake = () => {
    if (wrongChain) return;
    setAction("completing_unstake");
    writeContract({
      address: chain.stakingAddress as `0x${string}`,
      abi: GauloiStakingAbi,
      functionName: "completeUnstake",
    });
  };

  // Parse maker info — viem returns named tuple as an object
  const info = makerInfo as { stakedAmount: bigint; activeExposure: bigint; unstakeRequestTime: bigint; unstakeAmount: bigint; isActive: boolean } | undefined;
  const stakedAmount = info?.stakedAmount ?? 0n;
  const activeExposure = info?.activeExposure ?? 0n;
  const unstakeRequestTime = Number(info?.unstakeRequestTime ?? 0n);
  const pendingUnstakeAmount = info?.unstakeAmount ?? 0n;
  const isActive = info?.isActive ?? false;

  const availableCapacity = stakedAmount > activeExposure ? stakedAmount - activeExposure : 0n;
  const cooldownSeconds = cooldownRaw ? Number(cooldownRaw) : 0;
  const minStake = minStakeRaw ?? 0n;

  const hasPendingUnstake = unstakeRequestTime > 0;
  const unstakeAvailableAt = unstakeRequestTime + cooldownSeconds;
  const now = Math.floor(Date.now() / 1000);
  const cooldownComplete = hasPendingUnstake && now >= unstakeAvailableAt;
  const cooldownRemaining = hasPendingUnstake && !cooldownComplete ? unstakeAvailableAt - now : 0;

  const formatCooldown = (seconds: number) => {
    const m = Math.floor(seconds / 60);
    const s = seconds % 60;
    return m > 0 ? `${m}m ${s}s` : `${s}s`;
  };

  const stat = (label: string, value: string) => (
    <div className="flex justify-between items-center">
      <span className="font-pixel text-[8px] text-teal-600 uppercase">{label}</span>
      <span className="font-pixel text-[10px] text-pixel-cyan">{value}</span>
    </div>
  );

  return (
    <div className="pixel-border bg-navy-900 p-3 sm:p-4 space-y-3">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <ChainIcon chainId={chain.chainId} size={18} />
          <span className="font-pixel text-xs text-pixel-cyan">{chain.name.toUpperCase()}</span>
        </div>
        <span
          className={`font-pixel text-[8px] px-2 py-1 border-2 ${
            isActive
              ? "text-pixel-green border-pixel-green"
              : "text-pixel-red border-pixel-red"
          }`}
        >
          {isActive ? "ACTIVE" : "INACTIVE"}
        </span>
      </div>

      {/* Stats */}
      <div className="bg-navy-800 border-2 border-navy-600 p-3 space-y-2">
        {stat("Staked", `${formatUnits(stakedAmount, 6)} USDC`)}
        {stat("Exposure", `${formatUnits(activeExposure, 6)} USDC`)}
        {stat("Capacity", `${formatUnits(availableCapacity, 6)} USDC`)}
        {stat("Wallet", `${formatUnits(walletBalance ?? 0n, 6)} USDC`)}
        {stat("Min Stake", `${formatUnits(minStake, 6)} USDC`)}
      </div>

      {/* Switch chain warning */}
      {wrongChain && (
        <button
          onClick={() => switchChain({ chainId: chain.chainId })}
          className="w-full pixel-btn-amber text-[10px]"
        >
          SWITCH TO {chain.name.toUpperCase()}
        </button>
      )}

      {/* Stake form */}
      {!wrongChain && (
        <div className="bg-navy-800 border-2 border-navy-600 p-3 space-y-2">
          <label className="block font-pixel text-[8px] text-teal-600 uppercase">Stake USDC</label>
          <div className="flex gap-2">
            <input
              type="number"
              placeholder="0.00"
              value={stakeAmount}
              onChange={(e) => setStakeAmount(e.target.value)}
              className="flex-1 bg-transparent text-sm font-bold outline-none placeholder-navy-600 text-pixel-cyan"
            />
            <button
              onClick={() => setStakeAmount(formatUnits(walletBalance ?? 0n, 6))}
              className="font-pixel text-[8px] text-teal-600 hover:text-teal-400"
            >
              MAX
            </button>
          </div>
          <button
            onClick={handleStake}
            disabled={!stakeAmount || action !== "idle"}
            className="w-full pixel-btn text-[10px]"
          >
            {action === "approving"
              ? "APPROVING..."
              : action === "staking"
                ? "STAKING..."
                : "STAKE"}
          </button>
        </div>
      )}

      {/* Unstake section */}
      {!wrongChain && stakedAmount > 0n && (
        <div className="bg-navy-800 border-2 border-navy-600 p-3 space-y-2">
          <label className="block font-pixel text-[8px] text-teal-600 uppercase">Unstake</label>

          {hasPendingUnstake ? (
            cooldownComplete ? (
              <>
                <p className="font-pixel text-[8px] text-pixel-green">
                  COOLDOWN COMPLETE — {formatUnits(pendingUnstakeAmount, 6)} USDC READY
                </p>
                <button
                  onClick={handleCompleteUnstake}
                  disabled={action !== "idle"}
                  className="w-full pixel-btn text-[10px]"
                >
                  {action === "completing_unstake" ? "UNSTAKING..." : "COMPLETE UNSTAKE"}
                </button>
              </>
            ) : (
              <p className="font-pixel text-[8px] text-amber-400">
                COOLING DOWN — {formatUnits(pendingUnstakeAmount, 6)} USDC — {formatCooldown(cooldownRemaining)} REMAINING
              </p>
            )
          ) : (
            <>
              <div className="flex gap-2">
                <input
                  type="number"
                  placeholder="0.00"
                  value={unstakeAmount}
                  onChange={(e) => setUnstakeAmount(e.target.value)}
                  className="flex-1 bg-transparent text-sm font-bold outline-none placeholder-navy-600 text-pixel-cyan"
                />
                <button
                  onClick={() => setUnstakeAmount(formatUnits(availableCapacity, 6))}
                  className="font-pixel text-[8px] text-teal-600 hover:text-teal-400"
                >
                  MAX
                </button>
              </div>
              <button
                onClick={handleRequestUnstake}
                disabled={!unstakeAmount || action !== "idle"}
                className="w-full pixel-btn-amber text-[10px]"
              >
                {action === "requesting_unstake" ? "REQUESTING..." : "REQUEST UNSTAKE"}
              </button>
            </>
          )}
        </div>
      )}
    </div>
  );
}
