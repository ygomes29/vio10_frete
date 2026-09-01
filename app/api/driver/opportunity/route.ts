import { handleUserGet } from "@/lib/api/user-handler";
import { resolveDriverId } from "@/lib/services/driver";
import { getDriverOpportunity } from "@/lib/services/driver-reads";

/**
 * `GET /api/driver/opportunity` (driver-scoped — ADR-023 Fase 3). Ofertas
 * `status='pending'` e `expires_at > now()` dirigidas ao driver, com snapshot
 * da corrida + faixa de lance (min/max_driver_offer_cents). Polling ~10s na UI.
 */
export async function GET(request: Request): Promise<Response> {
  return handleUserGet(request, {
    eventType: "driver.opportunity",
    run: async (_corr, _url, ctx) => {
      const driverId = await resolveDriverId(ctx.client, ctx.user.id);
      if (!driverId) return { ok: false, reason: "not_authorized" };
      return getDriverOpportunity(ctx.client, driverId);
    },
  });
}