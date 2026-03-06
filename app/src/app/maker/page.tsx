"use client";

import { Suspense } from "react";
import { MakerDashboard } from "@/components/MakerDashboard";

export default function MakerPage() {
  return (
    <Suspense
      fallback={
        <div className="pixel-border bg-navy-900 p-6 text-center font-pixel text-[10px] text-teal-600 py-12">
          LOADING...
        </div>
      }
    >
      <MakerDashboard />
    </Suspense>
  );
}
