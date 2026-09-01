import "server-only";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { RpcResult } from "@/lib/rpc/result";

/**
 * Read-side do admin (Sessão 18 / ADR-024 D1/D7). Leitura direta via client
 * **user-scoped** (cookie JWT, `auth.uid()`, RLS `is_platform_admin()` aplica
 * cross-tenant — Sessão 04, 0017). **Sem `service_role`**, sem RPC (read-only).
 *
 * Cada fn retorna `RpcResult`-shaped p/ fluir pelo `handleAdminGet`→`toApiResponse`:
 * sucesso `{ ok:true, reason:null, ...payload }`; erro `{ ok:false, reason }`.
 *
 * Regra mestra: o dashboard só apresenta estado oficial; nada é inventado aqui.
 * Volume Congonhas MVP — agregação client-side pós-select (poucas centenas de rows).
 */

const ok = <T extends Record<string, unknown>>(payload: T): RpcResult => ({
  ok: true,
  reason: null,
  ...payload,
});
const fail = (reason: string): RpcResult => ({ ok: false, reason });

/** Status ativos (não-terminais) da máquina de entrega (ADR-016). */
const ACTIVE_STATUSES = [
  "draft",
  "quoted",
  "searching_driver",
  "assigned",
  "driver_to_pickup",
  "at_pickup",
  "picked_up",
  "in_transit",
] as const;
const TERMINAL_STATUSES = ["delivered", "cancelled", "failed", "expired"] as const;

/** Janela de retrospecção do overview (corridas ativas + terminais recentes). */
const OVERVIEW_WINDOW_HOURS = 72;
/** Limite de rows lidas p/ agregação client-side (volume MVP). */
const OVERVIEW_MAX_ROWS = 1000;
/** Limite máximo de drivers lidos p/ agregação de disponibilidade. */
const OVERVIEW_MAX_DRIVERS = 1000;

function isPgError(error: unknown, fallback = "internal_error"): string {
  if (!error) return fallback;
  const msg = String((error as { message?: string }).message ?? "");
  if (/policy|permission|denied/i.test(msg)) return "not_authorized";
  return fallback;
}

// ---- GET /api/admin/overview ----

type OverviewRow = {
  id: string;
  status: string;
  created_at: string;
  delivered_at: string | null;
  cancelled_at: string | null;
  failed_reason: string | null;
  cancelled_reason: string | null;
  delivery_quotes?: { customer_price_cents?: number | null } | { customer_price_cents?: number | null }[] | null;
};

type DriverRow = {
  id: string;
  account_status: string;
  current_availability_status: string;
};

export async function getOverview(client: SupabaseClient): Promise<RpcResult> {
  const since = new Date(Date.now() - OVERVIEW_WINDOW_HOURS * 3600_000).toISOString();

  const [delivRes, driverRes] = await Promise.all([
    client
      .from("delivery_requests")
      .select(
        "id, status, created_at, delivered_at, cancelled_at, failed_reason, cancelled_reason, delivery_quotes(customer_price_cents)",
      )
      .gte("created_at", since)
      .order("created_at", { ascending: false })
      .limit(OVERVIEW_MAX_ROWS),
    client
      .from("drivers")
      .select("id, account_status, current_availability_status")
      .limit(OVERVIEW_MAX_DRIVERS),
  ]);

  if (delivRes.error) return fail(isPgError(delivRes.error));
  if (driverRes.error) return fail(isPgError(driverRes.error));

  const rows = (delivRes.data ?? []) as OverviewRow[];
  const drivers = (driverRes.data ?? []) as DriverRow[];

  // Contagem por status (ativos + terminais recentes na janela).
  const byStatus: Record<string, number> = {};
  for (const r of rows) byStatus[r.status] = (byStatus[r.status] ?? 0) + 1;

  const active: Record<string, number> = {};
  for (const s of ACTIVE_STATUSES) if (byStatus[s]) active[s] = byStatus[s];
  const terminal: Record<string, number> = {};
  for (const s of TERMINAL_STATUSES) if (byStatus[s]) terminal[s] = byStatus[s];

  // Volume do dia (delivered hoje — soma customer_price_cents em centavos inteiros).
  const dayStart = new Date();
  dayStart.setHours(0, 0, 0, 0);
  let deliveredTodayCount = 0;
  let deliveredTodayCents = 0;
  for (const r of rows) {
    if (r.status !== "delivered" || !r.delivered_at) continue;
    if (new Date(r.delivered_at) < dayStart) continue;
    deliveredTodayCount += 1;
    const q = Array.isArray(r.delivery_quotes)
      ? r.delivery_quotes[0]
      : r.delivery_quotes;
    deliveredTodayCents += Number(q?.customer_price_cents) || 0;
  }

  // Falhas recentes (cancelled/failed/expired na janela, últimas 20).
  const failures = rows
    .filter(
      (r) =>
        r.status === "cancelled" ||
        r.status === "failed" ||
        r.status === "expired",
    )
    .slice(0, 20)
    .map((r) => ({
      id: r.id,
      status: r.status,
      created_at: r.created_at,
      cancelled_at: r.cancelled_at,
      reason: r.failed_reason ?? r.cancelled_reason ?? null,
    }));

  // Entregadores por disponibilidade (apenas ativos no sistema).
  const byAvail: Record<string, number> = {};
  let driversActive = 0;
  for (const d of drivers) {
    if (d.account_status !== "active") continue;
    driversActive += 1;
    byAvail[d.current_availability_status] =
      (byAvail[d.current_availability_status] ?? 0) + 1;
  }

  return ok({
    window_hours: OVERVIEW_WINDOW_HOURS,
    deliveries_by_status: { active, terminal },
    drivers: {
      active_total: driversActive,
      by_availability: byAvail,
    },
    delivered_today: {
      count: deliveredTodayCount,
      total_cents: deliveredTodayCents,
    },
    failures,
  });
}

// ---- GET /api/admin/deliveries ----

export type ListDeliveriesParams = {
  status?: string | null;
  businessId?: string | null;
  limit: number;
  offset: number;
};

export async function listDeliveries(
  client: SupabaseClient,
  params: ListDeliveriesParams,
): Promise<RpcResult> {
  const limit = Math.max(1, Math.min(100, params.limit));
  const offset = Math.max(0, params.offset);
  // fetch limit+1 para detectar próxima página sem count server-side.
  const fetchN = limit + 1;

  let q = client
    .from("delivery_requests")
    .select(
      [
        "id",
        "status",
        "created_at",
        "assigned_at",
        "picked_up_at",
        "in_transit_at",
        "delivered_at",
        "pickup_address",
        "delivery_address",
        "vehicle_required",
        "businesses!business_id(name)",
        // assignment ativa → driver (1:1 esperado; array p/ defesa).
        "delivery_assignments(status, assigned_at, drivers(full_name))",
      ].join(", "),
    )
    .order("created_at", { ascending: false })
    .range(offset, offset + fetchN - 1);

  if (params.status) q = q.eq("status", params.status);
  if (params.businessId) q = q.eq("business_id", params.businessId);

  const { data, error } = await q;
  if (error) return fail(isPgError(error));

  const rows = (data ?? []) as unknown[];
  const hasMore = rows.length > limit;
  const page = rows.slice(0, limit);

  return ok({
    deliveries: page,
    has_more: hasMore,
    limit,
    offset,
  });
}

// ---- GET /api/admin/deliveries/[id] ----

export async function getDeliveryDetail(
  client: SupabaseClient,
  id: string,
): Promise<RpcResult> {
  const { data, error } = await client
    .from("delivery_requests")
    .select(
      [
        "id",
        "status",
        "external_reference",
        "created_at",
        "assigned_at",
        "picked_up_at",
        "in_transit_at",
        "delivered_at",
        "cancelled_at",
        "cancelled_reason",
        "failed_reason",
        "scheduled_at",
        "vehicle_required",
        "pickup_address",
        "pickup_latitude",
        "pickup_longitude",
        "pickup_contact_name",
        "pickup_contact_phone",
        "delivery_address",
        "delivery_latitude",
        "delivery_longitude",
        "delivery_contact_name",
        "delivery_contact_phone",
        "instructions",
        "notes",
        "businesses!business_id(name)",
        "delivery_quotes(customer_price_cents, driver_offer_cents, base_cents, distance_component_cents, vehicle_component_cents, urgency_component_cents, dynamic_component_cents, subtotal_cents, platform_fee_cents, distance_meters, duration_seconds, status, confirmed_at, expires_at, min_customer_price_cents, max_customer_price_cents, min_driver_offer_cents, max_driver_offer_cents)",
        "delivery_items(id, description, quantity, weight_g, length_cm, width_cm, height_cm, notes)",
        // delivery_events FK de delivery_requests → timeline (ordena client-side por created_at).
        "delivery_events(id, event_type, actor_type, actor_id, from_status, to_status, metadata, correlation_id, created_at)",
        "proof_of_delivery(id, pod_type, storage_path, receiver_name, notes, captured_at)",
        // dispatch_rounds FK de delivery_requests (sem closed_reason — coluna não existe).
        "dispatch_rounds(id, round_number, status, search_radius_m, max_candidates, driver_offer_cents, opened_at, closed_at, expires_at)",
        // delivery_offers FK de delivery_requests (denormalizado) → bids por offer.
        // bids→delivery_offers é FK **composta** (`bids_offer_driver_fk`:
        // delivery_offer_id+driver_id → id+driver_id) — hint por coluna não resolve
        // FK composta no PostgREST (PGRST200); usar o nome da constraint. Achado live.
        "delivery_offers(id, driver_offer_cents, status, expires_at, created_at, responded_at, drivers(full_name), bids!bids_offer_driver_fk(id, response_type, bid_amount_cents, created_at))",
        // delivery_assignments FK de delivery_requests → driver (+ vehicle via driver.current_vehicle_id).
        "delivery_assignments(id, status, assigned_at, ended_at, ended_reason, drivers(full_name, phone, current_vehicle_id, vehicles!current_vehicle_id(plate, model, vehicle_type)))",
      ].join(", "),
    )
    .eq("id", id)
    .maybeSingle();

  if (error) return fail(isPgError(error));
  if (!data) return fail("not_found");

  // Ordena timeline por created_at (PostgREST não ordena arrays aninhados).
  const d = data as { delivery_events?: { created_at?: string }[] };
  if (Array.isArray(d.delivery_events)) {
    d.delivery_events.sort((a, b) =>
      String(a.created_at).localeCompare(String(b.created_at)),
    );
  }

  return ok({ delivery: data });
}

// ---- GET /api/admin/deliveries/[id]/positions ----

type PositionRow = {
  id: string;
  status: string;
  pickup_latitude: number;
  pickup_longitude: number;
  delivery_latitude: number;
  delivery_longitude: number;
  delivery_assignments?: {
    drivers?: {
      full_name?: string;
      driver_locations?: {
        position: unknown;
        captured_at: string;
        accuracy_m: number | null;
      } | null;
    } | null;
  } | null;
};

export type Point = { lat: number; lng: number };

/**
 * Parse de `geography(Point,4326)` retornado pelo PostgREST. **Formato real no
 * Supabase: hex EWKB** (`0101000020E6100000...` — Point + SRID 4326 + 2 doubles
 * little-endian), confirmado live. Fallbacks: GeoJSON `{type:"Point",coordinates:
 * [lng,lat]}` (lng primeiro) e WKT `POINT(lng lat)` — defesa p/ outros drivers.
 * **Sem migration** (ADR-024 D3) — `driver_locations` só tem `position` geography,
 * sem colunas lat/lng auxiliares; o parse acontece em TS (server-side).
 */
export function parsePointPosition(position: unknown): Point | null {
  if (!position) return null;
  // GeoJSON: { type:"Point", coordinates:[lng,lat] }
  if (typeof position === "object" && !Array.isArray(position)) {
    const coords = (position as { coordinates?: unknown }).coordinates;
    if (Array.isArray(coords) && coords.length >= 2) {
      const lng = Number(coords[0]);
      const lat = Number(coords[1]);
      if (Number.isFinite(lng) && Number.isFinite(lat)) return { lat, lng };
    }
  }
  if (typeof position === "string") {
    // EWKB hex (formato default do PostgREST/Supabase p/ geography):
    // byte0=order(01=LE), uint32 type (Point=1 | 0x20000000 se SRID), [uint32 SRID],
    // 2 float64 (lng, lat). Regex `0[01]` distingue de WKT ("POINT...").
    if (/^0[01][0-9a-f]*$/i.test(position)) {
      const parsed = parseEwkbPoint(position);
      if (parsed) return parsed;
    }
    // WKT fallback: "POINT(lng lat)"
    const m = position.match(/POINT\s*\(\s*(-?\d+\.?\d*)\s+(-?\d+\.?\d*)\s*\)/i);
    if (m) {
      const lng = Number(m[1]);
      const lat = Number(m[2]);
      if (Number.isFinite(lng) && Number.isFinite(lat)) return { lat, lng };
    }
  }
  return null;
}

/** Parse de EWKB hex de um Point (com ou sem SRID). Server-side (usa Buffer). */
function parseEwkbPoint(hex: string): Point | null {
  try {
    const bytes = Buffer.from(hex, "hex");
    if (bytes.length < 5) return null;
    const littleEndian = bytes[0] === 1;
    const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.length);
    const typeRaw = dv.getUint32(1, littleEndian);
    const hasSrid = (typeRaw & 0x20000000) !== 0;
    const geomType = typeRaw & 0x0fffffff;
    let off = 5;
    if (hasSrid) {
      if (bytes.length < 9) return null;
      off = 9; // pula SRID (uint32)
    }
    if (geomType !== 1 || bytes.length < off + 16) return null; // 1 = Point
    const lng = dv.getFloat64(off, littleEndian);
    const lat = dv.getFloat64(off + 8, littleEndian);
    if (Number.isFinite(lng) && Number.isFinite(lat)) return { lng, lat };
  } catch {
    return null;
  }
  return null;
}

export async function getDeliveryPositions(
  client: SupabaseClient,
  id: string,
): Promise<RpcResult> {
  const { data, error } = await client
    .from("delivery_requests")
    .select(
      [
        "id",
        "status",
        "pickup_latitude",
        "pickup_longitude",
        "delivery_latitude",
        "delivery_longitude",
        // assignment ativa → driver → última localização (driver_locations por driver_id).
        "delivery_assignments(status, drivers(full_name, driver_locations(position, captured_at, accuracy_m)))",
      ].join(", "),
    )
    .eq("id", id)
    .maybeSingle();

  if (error) return fail(isPgError(error));
  if (!data) return fail("not_found");

  const row = data as unknown as PositionRow;
  const pickup: Point = { lat: row.pickup_latitude, lng: row.pickup_longitude };
  const delivery: Point = { lat: row.delivery_latitude, lng: row.delivery_longitude };

  let driver: {
    full_name: string | null;
    position: Point | null;
    captured_at: string | null;
    accuracy_m: number | null;
  } | null = null;

  const assignments = row.delivery_assignments;
  if (assignments) {
    // Pode vir como objeto (1:1) ou array; normalize.
    const arr = Array.isArray(assignments) ? assignments : [assignments];
    const active = arr.find((a) => a?.status === "active");
    const dr = active?.drivers;
    if (dr) {
      const loc = dr.driver_locations;
      // driver_locations pode ser objeto (1:1 por driver) ou array.
      const locObj = Array.isArray(loc) ? loc[0] : loc;
      driver = {
        full_name: dr.full_name ?? null,
        position: locObj ? parsePointPosition(locObj.position) : null,
        captured_at: locObj?.captured_at ?? null,
        accuracy_m: locObj?.accuracy_m ?? null,
      };
    }
  }

  return ok({
    id: row.id,
    status: row.status ?? null,
    pickup,
    delivery,
    driver,
  });
}