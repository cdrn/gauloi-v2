import { useCallback, useEffect, useRef, useState } from "react";
import type { OrderMessage } from "@gauloi/common";

interface Quote {
  intentId: string;
  maker: string;
  outputAmount: string;
  estimatedFillTime: number;
  expiry: number;
  signature: string;
}

interface UseRelayOptions {
  url: string;
  enabled?: boolean;
}

export function useRelay({ url, enabled = true }: UseRelayOptions) {
  const wsRef = useRef<WebSocket | null>(null);
  const [connected, setConnected] = useState(false);
  const [quotes, setQuotes] = useState<Quote[]>([]);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!enabled) return;

    const ws = new WebSocket(url);
    wsRef.current = ws;

    ws.onopen = () => setConnected(true);
    ws.onclose = () => setConnected(false);
    ws.onerror = () => setError("Failed to connect to relay");

    ws.onmessage = (event) => {
      const msg = JSON.parse(event.data);
      if (msg.type === "quote_received") {
        setQuotes((prev) => [...prev, msg.data]);
      }
      if (msg.type === "error") {
        setError(msg.data.message);
      }
    };

    return () => {
      ws.close();
      wsRef.current = null;
    };
  }, [url, enabled]);

  const broadcast = useCallback(
    (
      intentId: string,
      order: OrderMessage,
      signature: string,
      sourceChainId: number,
    ) => {
      if (!wsRef.current || wsRef.current.readyState !== WebSocket.OPEN) return;

      setQuotes([]);
      setError(null);

      wsRef.current.send(
        JSON.stringify({
          type: "intent_broadcast",
          data: {
            intentId,
            taker: order.taker,
            inputToken: order.inputToken,
            inputAmount: order.inputAmount.toString(),
            outputToken: order.outputToken,
            destinationChainId: Number(order.destinationChainId),
            destinationAddress: order.destinationAddress,
            minOutputAmount: order.minOutputAmount.toString(),
            expiry: Number(order.expiry),
            nonce: order.nonce.toString(),
            takerSignature: signature,
            sourceChainId,
          },
        }),
      );
    },
    [],
  );

  const selectQuote = useCallback((intentId: string, maker: string) => {
    if (!wsRef.current || wsRef.current.readyState !== WebSocket.OPEN) return;

    wsRef.current.send(
      JSON.stringify({
        type: "quote_select",
        data: { intentId, maker },
      }),
    );
  }, []);

  return { connected, quotes, error, broadcast, selectQuote };
}
