import { handleUserPost } from "@/lib/api/user-handler";
import {
  validateAvailabilityBody,
  setDriverAvailability,
  resolveDriverId,
  type AvailabilityInput,
} from "@/lib/services/driver";

/**
 * `POST /api/driver/availability` → `set_driver_availability` (driver-scoped).
 * Cookie JWT (user-scoped). Resolve `drivers.id` de `auth.uid()` (RLS self).
 * Driver self-toggle: `available`, `paused`, `offline` (offered/busy são
 * system-set durante dispatch — não aceitos aqui). `set_driver_availability`
 * raise `'not_authorized'` (void, não returns-table) → 403 via reasonToStatus.
 *
 * Handler custom (não usa opts.run genérica) pois precisa resolver driverId
 * antes de chamar o service e mapear "não é driver" → 403.
 */
export async function POST(request: Request): Promise<Response> {
  return handleUserPost(request, {
    eventType: "driver.availability",
    validate: (b) => {
      const r = validateAvailabilityBody(b);
      return r.valid ? null : r.reason;
    },
    run: async (_correlationId, body, ctx) => {
      const driverId = await resolveDriverId(ctx.client, ctx.user.id);
      if (!driverId) {
        // usuário autenticado mas não é driver (sem row em drivers p/ este user)
        return { ok: false, reason: "not_authorized" };
      }
      const b = body as { status: AvailabilityInput["status"]; reason?: string | null };
      return setDriverAvailability(ctx.client, {
        driverId,
        status: b.status,
        reason: b.reason ?? null,
      });
    },
  });
}