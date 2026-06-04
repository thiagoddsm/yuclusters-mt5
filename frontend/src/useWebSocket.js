import { useEffect, useRef, useState } from 'react';

export function useWebSocket(url, onMessageCallback) {
  const [status, setStatus] = useState('disconnected');
  const wsRef = useRef(null);
  const reconnectTimeoutRef = useRef(null);

  useEffect(() => {
    let active = true;

    function connect() {
      if (!active) return;
      setStatus('connecting');
      
      const ws = new WebSocket(url);
      wsRef.current = ws;

      ws.onopen = () => {
        if (!active) return;
        setStatus('connected');
      };

      ws.onmessage = (event) => {
        if (!active) return;
        try {
          const data = JSON.parse(event.data);
          onMessageCallback(data);
        } catch (e) {
          console.error("Error parsing WS message:", e);
        }
      };

      ws.onclose = () => {
        if (!active) return;
        setStatus('disconnected');
        reconnectTimeoutRef.current = setTimeout(connect, 3000);
      };

      ws.onerror = (err) => {
        console.error("WS connection error:", err);
        ws.close();
      };
    }

    connect();

    return () => {
      active = false;
      if (wsRef.current) wsRef.current.close();
      if (reconnectTimeoutRef.current) clearTimeout(reconnectTimeoutRef.current);
    };
  }, [url, onMessageCallback]);

  return status;
}
