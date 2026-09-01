import { handleUserPost } from "@/lib/api/user-handler";
import {
  validateDriverLocationBody,
  resolveDriverId,
  type DriverLocationInput,
} from "@/lib/services/driver";
import { upsertDriverLocation } from "@/lib/services/driver-reads";

/**
 * `POST /api/driver/location` (driver-scoped, cookie JWT — ADR-023 Fase 3 / D8).
 * Telemetria: upsert em `driver_locations` (única mutação direta do authenticated,
 * RLS `driver_id = my_driver_id()`). `position` = WKT `POINT(lng lat)`. Sem RPC.
 * Lat/lng finitos, `captured_at` ISO. Erro de policy → 403 not_authorized.
 */
export async function POST(request: Request): Promise<Response> {
  return handleUserPost(request, {
    eventType: "driver.location",
    validate: (b) => {
      const r = validateDriverLocationBody(b);
      return r.valid ? null : r.reason;
    },
    run: async (_corr, body, ctx) => {
      const driverId = await resolveDriverId(ctx.client, ctx.user.id);
      if (!driverId) return { ok: false, reason: "not_authorized" };
      const b = body as {
        latitude: number;
        longitude: number;
        accuracy_m?: number | null;
        heading_deg?: number | null;
        speed_mps?: number | null;
        captured_at: string;
      };
      const input: DriverLocationInput = {
        latitude: b.latitude,
        longitude: b.longitude,
        accuracyM: b.accuracy_m ?? null,
        headingDeg: b.heading_deg ?? null,
        speedMps: b.speed_mps ?? null,
        capturedAt: b.captured_at,
      };
      return upsertDriverLocation(ctx.client, driverId, input);
    },
    sensitive: false,
  });
}