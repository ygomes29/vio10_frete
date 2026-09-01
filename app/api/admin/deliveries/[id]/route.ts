import { handleAdminGet } from "@/lib/api/admin-handler";
import { getDeliveryDetail } from "@/lib/services/admin-reads";

/**
 * `GET /api/admin/deliveries/{id}` (admin-scoped — Sessão 18 / ADR-024 D1).
 * Detalhe completo: corrida + quote + items + timeline (`delivery_events`) + POD
 * + rodadas + offers/bids + assignment/driver/vehicle. Leitura user-scoped (RLS).
 * Read-only.
 */
export async function GET(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  const { id } = await params;
  return handleAdminGet(request, {
    eventType: "admin.deliveries.detail",
    run: async (_corr, _url, ctx) => getDeliveryDetail(ctx.client, id),
  });
}