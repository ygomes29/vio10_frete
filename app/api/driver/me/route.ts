import { handleUserGet } from "@/lib/api/user-handler";
import { resolveDriverId } from "@/lib/services/driver";
import { getDriverMe } from "@/lib/services/driver-reads";

/**
 * `GET /api/driver/me` (driver-scoped, cookie JWT — ADR-023 Fase 3). Perfil +
 * disponibilidade + veículo atual. RLS self (`user_id = auth.uid()`).
 */
export async function GET(request: Request): Promise<Response> {
  return handleUserGet(request, {
    eventType: "driver.me",
    run: async (_corr, _url, ctx) => {
      const driverId = await resolveDriverId(ctx.client, ctx.user.id);
      if (!driverId) return { ok: false, reason: "not_authorized" };
      return getDriverMe(ctx.client, driverId);
    },
  });
}