import "server-only";

/**
 * Abstração de provider de geocoding (ADR-005). O domínio nunca chama Google Maps
 * direto. Implementação real (Google Maps) → Sessão 20. Por ora, **nenhuma** impl
 * registrada → os Route Handlers `/enrich` e `/quote` retornam 501
 * "geo provider not configured" (ADR-019 D5 — não simulado, regra mestra).
 */

export type GeocodedPoint = {
  lat: number;
  lng: number;
  /** qualidade/precisão do geocode (provider-specific) */
  quality?: string;
  /** endereço normalizado/validado, se aplicável */
  formattedAddress?: string;
};

export type GeocodingProvider = {
  /** address → coordenadas + validação. */
  geocode(address: string): Promise<GeocodedPoint>;
  /** coordenadas → endereço. */
  reverse(lat: number, lng: number): Promise<{ formattedAddress: string }>;
  /** validação/normalização de endereço. */
  validateAddress(address: string): Promise<{ valid: boolean; normalized?: string; ambiguities?: string[] }>;
};

let registered: GeocodingProvider | null = null;

export function registerGeocodingProvider(provider: GeocodingProvider): void {
  registered = provider;
}

export function getGeocodingProvider(): GeocodingProvider | null {
  return registered;
}

export function isGeocodingAvailable(): boolean {
  return registered !== null;
}