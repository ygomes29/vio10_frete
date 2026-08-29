import { handleInternalPost } from "@/lib/api/internal-handler";
import { quoteDelivery } from "@/lib/services/geo";

/**
 * `POST /api/internal/deliveries/{id}/quote` → `RoutingProvider.route` + `create_quote`
 * (system-only, ADR-012 D1). Trust boundary: distância/duração vêm do **provider**
 * (plataforma), nunca do business (ADR-019 D5). **Sem provider até Sessão 20** → 501
 * `geo_provider_not_configured` (não simulado — regra mestra; nunca haversine p/ pricing,
 * ADR-012 D2). Body: `{ travel_mode?, pickup:{lat,lng}, destination:{lat,lng} }`.
 */
export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  const { id } = await params;
  return handleInternalPost(request, {
    eventType: "delivery.quote",
    source: "internal-api",
    validate: (b) => {
      if (!b || typeof b !== "object") return "invalid_param";
      const bo = b as { pickup?: unknown; destination?: unknown; travel_mode?: unknown };
      for (const k of ["pickup", "destination"] as const) {
        const p = bo[k] as { lat?: unknown; lng?: unknown } | undefined;
        if (!p || typeof p !== "object") return "invalid_param";
        if (typeof p.lat !== "number" || typeof p.lng !== "number") return "invalid_param";
      }
      if (bo.travel_mode !== undefined && bo.travel_mode !== "CAR" && bo.travel_mode !== "TWO_WHEELER") {
        return "invalid_param";
      }
      return null;
    },
    run: (correlationId, body) => {
      const b = body as {
        travel_mode?: "CAR" | "TWO_WHEELER";
        pickup: { lat: number; lng: number };
        destination: { lat: number; lng: number };
      };
      return quoteDelivery(id, { travelMode: b.travel_mode, pickup: b.pickup, destination: b.destination }, correlationId);
    },
  });
}