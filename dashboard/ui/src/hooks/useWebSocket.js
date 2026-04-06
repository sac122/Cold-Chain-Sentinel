import { useEffect, useRef, useCallback } from "react";

const WS_URL =
  typeof window !== "undefined"
    ? `${window.location.protocol === "https:" ? "wss" : "ws"}://${window.location.host}/ws`
    : "ws://localhost:5001/ws";

/**
 * useWebSocket(onMessage, onOpen, onClose)
 *
 * Maintains a WebSocket connection with automatic exponential-backoff
 * reconnection.  Calls onMessage(parsedObject) for every incoming message.
 * Returns a `send(obj)` callback.
 */
export function useWebSocket(onMessage, onOpen, onClose) {
  const wsRef       = useRef(null);
  const retryRef    = useRef(0);
  const mountedRef  = useRef(true);
  const pingRef     = useRef(null);

  const connect = useCallback(() => {
    if (!mountedRef.current) return;
    const ws = new WebSocket(WS_URL);
    wsRef.current = ws;

    ws.onopen = () => {
      retryRef.current = 0;
      onOpen?.();
      // Keep-alive ping every 20 s
      pingRef.current = setInterval(() => {
        if (ws.readyState === WebSocket.OPEN)
          ws.send(JSON.stringify({ type: "ping" }));
      }, 20_000);
    };

    ws.onmessage = (e) => {
      try { onMessage(JSON.parse(e.data)); } catch { /* ignore */ }
    };

    ws.onclose = () => {
      clearInterval(pingRef.current);
      onClose?.();
      if (!mountedRef.current) return;
      // Exponential back-off: 1s, 2s, 4s … capped at 30s
      const delay = Math.min(1000 * 2 ** retryRef.current, 30_000);
      retryRef.current += 1;
      setTimeout(connect, delay);
    };

    ws.onerror = () => ws.close();
  }, [onMessage, onOpen, onClose]);

  useEffect(() => {
    mountedRef.current = true;
    connect();
    return () => {
      mountedRef.current = false;
      clearInterval(pingRef.current);
      wsRef.current?.close();
    };
  }, [connect]);

  const send = useCallback((obj) => {
    if (wsRef.current?.readyState === WebSocket.OPEN)
      wsRef.current.send(JSON.stringify(obj));
  }, []);

  return send;
}
