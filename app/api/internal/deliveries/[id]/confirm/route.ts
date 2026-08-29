import { handleInternalPost } from "@/lib/api/internal-handler";
import { confirmDelivery } from "@/lib/services/deliveries";

/**
 * `POST /api/internal/deliveries/{id}/confirm` → `confirm_delivery` (system-only,
 * ADR-017). Valida POD + chama `transition_delivery('delivered')` que re-valida o
 * gate (POD + geo + pickup). `p_geo_tolerance_m` opcional (default 200m, ADR-017 D2).
 */
export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  const { id } = await params;
  return handleInternalPost(request, {
    eventType: "delivery.confirm",
    source: "internal-api",
    run: (correlationId, body) => {
      const b = (body ?? {}) as { geo_tolerance_m?: number };
      return confirmDelivery(id, { geoToleranceM: b.geo_tolerance_m }, correlationId);
    },
  });
}