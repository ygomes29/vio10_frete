import { handleBusinessGet } from "@/lib/api/business-handler";
import { getDeliveryPositions } from "@/lib/services/business-reads";

/**
 * `GET /api/business/deliveries/{id}/positions` (business-scoped — Sessão 19 / ADR-025
 * D3). Leve, p/ **polling do mapa** (15s). Coords pickup/delivery (double) + entregador
 * atual (assignment active → `driver_locations.position` → parse EWKB hex em TS, sem
 * migration). RLS escopa ao tenant. Read-only.
 */
export async function GET(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  const { id } = await params;
  return handleBusinessGet(request, {
    eventType: "business.deliveries.positions",
    run: async (_corr, _url, ctx) => getDeliveryPositions(ctx.client, id),
  });
}