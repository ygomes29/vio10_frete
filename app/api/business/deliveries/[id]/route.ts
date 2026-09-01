import { handleBusinessGet } from "@/lib/api/business-handler";
import { getDeliveryDetail } from "@/lib/services/business-reads";

/**
 * `GET /api/business/deliveries/{id}` (business-scoped — Sessão 19 / ADR-025 D1).
 * Detalhe completo: corrida + quote + items + timeline (`delivery_events`) + POD
 * + rodadas + offers/bids + assignment/driver/vehicle. RLS `can_view_delivery_request`
 * escopa ao tenant; corrida de outra org → `not_found` (422). Read-only.
 */
export async function GET(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  const { id } = await params;
  return handleBusinessGet(request, {
    eventType: "business.deliveries.detail",
    run: async (_corr, _url, ctx) => getDeliveryDetail(ctx.client, id),
  });
}