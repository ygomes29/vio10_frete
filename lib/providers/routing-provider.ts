import "server-only";

/**
 * Abstração de provider de rotas (ADR-005). Implementação real (Google Maps Routes,
 * com `TWO_WHEELER` p/ motos — essencial p/ ViO10) → Sessão 20. Por ora, **nenhuma**
 * impl registrada → `/quote` retorna 501 "geo provider not configured" (ADR-019 D5).
 *
 * Trust boundary do pricing (ADR-012 D1): distância/duração vêm do **provider**
 * (plataforma), **nunca** do business. **Não** usar distância em linha reta
 * (haversine) para pricing — violaria ADR-012 D2.
 */

export type TravelMode = "CAR" | "TWO_WHEELER";

export type RouteResult = {
  distanceMeters: number;
  durationSeconds: number;
  /** polyline codificada, se o provider fornecer */
  polyline?: string;
};

export type RoutingProvider = {
  route(origin: GeocodedPointLike, destination: GeocodedPointLike, opts: { travelMode: TravelMode }): Promise<RouteResult>;
  eta(origin: GeocodedPointLike, destination: GeocodedPointLike, opts: { travelMode: TravelMode }): Promise<{ durationSeconds: number }>;
};

export type GeocodedPointLike = { lat: number; lng: number };

let registered: RoutingProvider | null = null;

export function registerRoutingProvider(provider: RoutingProvider): void {
  registered = provider;
}

export function getRoutingProvider(): RoutingProvider | null {
  return registered;
}

export function isRoutingAvailable(): boolean {
  return registered !== null;
}