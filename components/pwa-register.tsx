"use client";

import { useEffect } from "react";

/**
 * Registra o service worker do PWA Entregador (ADR-023 Fase 1 / D4). SW em
 * `public/sw.js` (servido na raiz — padrão doc Next 16). Roda só no browser;
 * silencia se SW indisponível.
 */
export function PWARegister() {
  useEffect(() => {
    if (typeof navigator === "undefined" || !("serviceWorker" in navigator)) return;
    const register = () => {
      navigator.serviceWorker
        .register("/sw.js", { scope: "/", updateViaCache: "none" })
        .catch(() => undefined);
    };
    register();
    window.addEventListener("load", register, { once: true });
  }, []);
  return null;
}