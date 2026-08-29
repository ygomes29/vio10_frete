import { handleInternalPost } from "@/lib/api/internal-handler";
import { enrichDelivery } from "@/lib/services/geo";

/**
 * `POST /api/internal/deliveries/{id}/enrich` → `GeocodingProvider.geocode` +
 * validação de endereço (ADR-005). **Sem provider até Sessão 20** → 501
 * `geo_provider_not_configured` (não simulado — regra mestra).
 */
export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  const { id } = await params;
  return handleInternalPost(request, {
    eventType: "delivery.enrich",
    source: "internal-api",
    run: (correlationId) => enrichDelivery(id, correlationId).then(() => ({ ok: true, reason: null })),
  });
}