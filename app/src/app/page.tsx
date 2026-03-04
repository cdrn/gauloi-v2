"use client";

import { useSearchParams } from "next/navigation";
import { SwapForm, type SwapInitialParams } from "@/components/SwapForm";
import { Suspense } from "react";

function SwapPage() {
  const searchParams = useSearchParams();

  const to = searchParams.get("to");
  const token = searchParams.get("token");
  const amount = searchParams.get("amount");
  const recipient = searchParams.get("recipient");

  const initialParams: SwapInitialParams | undefined =
    to || token || amount || recipient
      ? {
          destChainId: to ? parseInt(to, 10) : undefined,
          token: token ?? undefined,
          amount: amount ?? undefined,
          recipient: recipient as `0x${string}` | undefined,
        }
      : undefined;

  return <SwapForm initialParams={initialParams} />;
}

export default function Home() {
  return (
    <Suspense fallback={<div className="pixel-border bg-navy-900 p-6 text-center font-pixel text-[10px] text-teal-600 py-12">LOADING...</div>}>
      <SwapPage />
    </Suspense>
  );
}
