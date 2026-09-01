import { handleUserGet } from "@/lib/api/user-handler";
import { resolveDriverId } from "@/lib/services/driver";
import { getActiveDelivery } from "@/lib/services/driver-reads";

/**
 * `GET /api/driver/deliveries/active` (driver-scoped — ADR-023 Fase 3). Corrida
 * com assignment ativa (`status='active'`, `ended_at is null`) e
 * `delivery_requests.status` em assigned..in_transit. Inclui snapshot, preço
 * acordado (via delivery_offer_id/bid_id — assignment não tem coluna de preço),
 * PODs submetidos e timeline de eventos. `active: null` se nenhuma.
 */
export async function GET(request: Request): Promise<Response> {
  return handleUserGet(request, {
    eventType: "driver.active_delivery",
    run: async (_corr, _url, ctx) => {
      const driverId = await resolveDriverId(ctx.client, ctx.user.id);
      if (!driverId) return { ok: false, reason: "not_authorized" };
      return getActiveDelivery(ctx.client, driverId);
    },
  });
}