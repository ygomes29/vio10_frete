import { handleUserGet } from "@/lib/api/user-handler";
import { resolveDriverId } from "@/lib/services/driver";
import { getEarnings } from "@/lib/services/driver-reads";

/**
 * `GET /api/driver/earnings` (driver-scoped — ADR-023 Fase 3). Soma do preço
 * acordado das entregas `delivered` (assignment `completed`) nos últimos 30 dias.
 * Preço = bid_amount_cents (contra-lance vencedor) ?? driver_offer_cents (aceite).
 */
export async function GET(request: Request): Promise<Response> {
  return handleUserGet(request, {
    eventType: "driver.earnings",
    run: async (_corr, _url, ctx) => {
      const driverId = await resolveDriverId(ctx.client, ctx.user.id);
      if (!driverId) return { ok: false, reason: "not_authorized" };
      return getEarnings(ctx.client, driverId);
    },
  });
}