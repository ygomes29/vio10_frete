"use client";

import { useDriverLocation } from "@/lib/hooks/use-driver-location";

/** Wrapper client para o hook de telemetria (ADR-023 Fase 4 / D8). Renderiza
 * nada; só ativa o watchPosition quando `enabled` (corrida ativa + foreground). */
export function LocationTracker({ enabled }: { enabled: boolean }) {
  useDriverLocation(enabled);
  return null;
}