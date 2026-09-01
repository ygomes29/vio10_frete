import { handleUserGet } from "@/lib/api/user-handler";
import { resolveDriverId } from "@/lib/services/driver";
import { getDeliveryHistory } from "@/lib/services/driver-reads";

/**
 * `GET /api/driver/deliveries/history?limit=` (driver-scoped — ADR-023 Fase 3).
 * Assignments encerradas (`ended_at not null`) join delivery_requests + preço.
 * `limit` clampado em [1,50], default 20.
 */
export async function GET(request: Request): Promise<Response> {
  return handleUserGet(request, {
    eventType: "driver.history",
    run: async (_corr, url, ctx) => {
      const driverId = await resolveDriverId(ctx.client, ctx.user.id);
      if (!driverId) return { ok: false, reason: "not_authorized" };
      const raw = Number(url.searchParams.get("limit") ?? "20");
      return getDeliveryHistory(ctx.client, driverId, Number.isFinite(raw) ? raw : 20);
    },
  });
}