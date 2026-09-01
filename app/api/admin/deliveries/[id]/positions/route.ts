import { handleAdminGet } from "@/lib/api/admin-handler";
import { getDeliveryPositions } from "@/lib/services/admin-reads";

/**
 * `GET /api/admin/deliveries/{id}/positions` (admin-scoped — Sessão 18 / ADR-024
 * D3). Leve, p/ **polling do mapa** (15s). Coords pickup/delivery (double) +
 * entregador atual (assignment active → `driver_locations.position` → parse
 * GeoJSON em TS, sem migration). Leitura user-scoped (RLS). Read-only.
 */
export async function GET(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  const { id } = await params;
  return handleAdminGet(request, {
    eventType: "admin.deliveries.positions",
    run: async (_corr, _url, ctx) => getDeliveryPositions(ctx.client, id),
  });
}