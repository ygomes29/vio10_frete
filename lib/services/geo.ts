import "server-only";
import { createSystemClient } from "@/lib/supabase/system-client";
import { callRpc } from "@/lib/rpc/call";
import type { RpcResult } from "@/lib/rpc/result";
import { getRoutingProvider, isRoutingAvailable, type TravelMode } from "@/lib/providers/routing-provider";
import { isGeocodingAvailable } from "@/lib/providers/geocoding-provider";

export class ProviderNotConfiguredError extends Error {
  reason = "geo_provider_not_configured";
  status = 501;
}

/**
 * `POST /api/internal/deliveries/{id}/quote` → `RoutingProvider.route` +
 * `create_quote` (system-only, ADR-012 D1). Trust boundary: distância/duração vêm
 * do **provider** (plataforma), nunca do business (ADR-019 D5).
 *
 * **Sem provider registrado até a Sessão 20** → lança `ProviderNotConfiguredError`
 * (handler retorna 501). **Não** usar haversine para pricing (violaria ADR-012 D2).
 */
export async function quoteDelivery(
  deliveryId: string,
  opts: { travelMode?: TravelMode; pickup: { lat: number; lng: number }; destination: { lat: number; lng: number } },
  correlationId: string,
): Promise<RpcResult> {
  if (!isRoutingAvailable()) throw new ProviderNotConfiguredError();
  const provider = getRoutingProvider()!;
  const route = await provider.route(opts.pickup, opts.destination, {
    travelMode: opts.travelMode ?? "TWO_WHEELER",
  });
  const client = createSystemClient();
  return callRpc(client, "create_quote", {
    p_delivery_request_id: deliveryId,
    p_distance_meters: route.distanceMeters,
    p_duration_seconds: route.durationSeconds,
    p_correlation_id: correlationId,
  });
}

/**
 * `POST /api/internal/deliveries/{id}/enrich` → `GeocodingProvider.geocode` +
 * validação. **Sem provider até Sessão 20** → 501.
 */
export async function enrichDelivery(deliveryId: string, _correlationId: string): Promise<void> {
  if (!isGeocodingAvailable()) throw new ProviderNotConfiguredError();
  // Sessão 20: GeocodingProvider.geocode + reverse + validateAddress + persistência.
  void deliveryId;
}