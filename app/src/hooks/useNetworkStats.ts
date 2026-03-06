import { useEffect, useState } from "react";

export interface NetworkStats {
  makers: Record<string, { count: number; addresses: string[] }>;
  intents: { total: number; open: number; filled: number; volume: string };
}

const RELAY_HTTP_URL = (process.env.NEXT_PUBLIC_RELAY_URL ?? "ws://127.0.0.1:8080")
  .replace("wss://", "https://")
  .replace("ws://", "http://");

export function useNetworkStats(intervalMs = 15_000): NetworkStats | null {
  const [stats, setStats] = useState<NetworkStats | null>(null);

  useEffect(() => {
    let active = true;

    const fetchStats = async () => {
      try {
        const res = await fetch(`${RELAY_HTTP_URL}/stats`);
        if (!res.ok) return;
        const data = await res.json();
        if (active) setStats(data);
      } catch {
        // non-fatal
      }
    };

    fetchStats();
    const id = setInterval(fetchStats, intervalMs);
    return () => {
      active = false;
      clearInterval(id);
    };
  }, [intervalMs]);

  return stats;
}
