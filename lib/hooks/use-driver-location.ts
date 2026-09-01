"use client";

import { useEffect, useRef } from "react";
import { apiPost } from "@/lib/client/fetcher";

/**
 * Telemetria de localização do entregador (ADR-023 Fase 4 / D8, GEOLOCATION.md).
 * Só ativa durante corrida ativa (`enabled`) E com PWA em foreground
 * (`visibilityState === 'visible'`). Não presume rastreamento confiável em
 * background — tracking persistente exigiria app nativo. Posta no máximo a cada
 * `intervalMs` (default 10s) para `/api/driver/location` (cookie JWT, RLS).
 */
export function useDriverLocation(enabled: boolean, intervalMs = 10_000): void {
  const watchIdRef = useRef<number | null>(null);
  const lastSentRef = useRef(0);
  const pendingRef = useRef<GeolocationPosition | null>(null);

  useEffect(() => {
    if (!enabled || typeof navigator === "undefined" || !navigator.geolocation) return;

    const send = (pos: GeolocationPosition) => {
      const now = Date.now();
      if (now - lastSentRef.current < intervalMs) {
        pendingRef.current = pos; // envia no próximo tick
        return;
      }
      lastSentRef.current = now;
      void apiPost("/api/driver/location", {
        latitude: pos.coords.latitude,
        longitude: pos.coords.longitude,
        accuracy_m: pos.coords.accuracy ?? null,
        heading_deg: Number.isFinite(pos.coords.heading) ? pos.coords.heading : null,
        speed_mps: Number.isFinite(pos.coords.speed) ? pos.coords.speed : null,
        captured_at: new Date(pos.timestamp).toISOString(),
      });
    };

    const start = () => {
      if (watchIdRef.current != null) return;
      watchIdRef.current = navigator.geolocation.watchPosition(
        (pos) => {
          if (document.visibilityState === "visible") send(pos);
        },
        () => undefined, // GPS indisponível: não é erro de negócio; silencia
        { enableHighAccuracy: true, maximumAge: 5000, timeout: 15000 },
      );
    };
    const stop = () => {
      if (watchIdRef.current != null) {
        navigator.geolocation.clearWatch(watchIdRef.current);
        watchIdRef.current = null;
      }
    };

    const onVisibility = () => {
      if (document.visibilityState === "visible") {
        start();
        if (pendingRef.current) send(pendingRef.current);
      } else {
        stop();
      }
    };

    if (document.visibilityState === "visible") start();
    document.addEventListener("visibilitychange", onVisibility);

    // Heartbeat: se houver leitura pendente não-enviada (rate-limited), reenvia.
    const hb = window.setInterval(() => {
      if (document.visibilityState === "visible" && pendingRef.current) send(pendingRef.current);
    }, intervalMs);

    return () => {
      stop();
      document.removeEventListener("visibilitychange", onVisibility);
      window.clearInterval(hb);
    };
  }, [enabled, intervalMs]);
}