import "server-only";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { RpcResult } from "@/lib/rpc/result";
import type { DriverLocationInput } from "./driver";

/**
 * Read-side do driver (ADR-023 Fase 3 / D1). Leitura direta via client user-scoped
 * (RLS — `can_view_delivery_request`, `my_driver_id`). **Sem RPC**: a única exceção
 * histórica de mutação direta do `authenticated` é `driver_locations` (0015/0017).
 *
 * Cada fn retorna `RpcResult`-shaped p/ fluir pelo `handleUserGet`→`toApiResponse`:
 * sucesso `{ ok:true, reason:null, ...payload }`; erro `{ ok:false, reason }`.
 *
 * Regra mestra: o frontend só lê estado oficial; nada é inventado aqui.
 */

const ok = <T extends Record<string, unknown>>(payload: T): RpcResult => ({
  ok: true,
  reason: null,
  ...payload,
});
const fail = (reason: string): RpcResult => ({ ok: false, reason });

// ---- GET /api/driver/me ----

export async function getDriverMe(
  client: SupabaseClient,
  driverId: string,
): Promise<RpcResult> {
  const { data, error } = await client
    .from("drivers")
    .select(
      "id, full_name, phone, account_status, current_availability_status, current_vehicle_id, vehicles!current_vehicle_id(id, plate, model, vehicle_type)",
    )
    .eq("id", driverId)
    .maybeSingle();
  if (error || !data) return fail("not_found");
  return ok({ me: data });
}

// ---- GET /api/driver/opportunity ----

export async function getDriverOpportunity(
  client: SupabaseClient,
  driverId: string,
): Promise<RpcResult> {
  const { data, error } = await client
    .from("delivery_offers")
    .select(
      [
        "id",
        "delivery_request_id",
        "driver_offer_cents",
        "status",
        "expires_at",
        "created_at",
        "delivery_requests(id, status, pickup_address, delivery_address, pickup_contact_name, pickup_contact_phone, delivery_contact_name, vehicle_required, scheduled_at, instructions",
        "delivery_quotes(driver_offer_cents, min_driver_offer_cents, max_driver_offer_cents, distance_meters, duration_seconds)",
        "delivery_items(id, description, quantity, weight_g))",
      ].join(", "),
    )
    .eq("driver_id", driverId)
    .eq("status", "pending")
    .gt("expires_at", new Date().toISOString())
    .order("created_at", { ascending: true });
  if (error) return fail("internal_error");
  return ok({ opportunities: data ?? [] });
}

// ---- GET /api/driver/deliveries/active ----

const ACTIVE_STATUSES = new Set([
  "assigned",
  "driver_to_pickup",
  "at_pickup",
  "picked_up",
  "in_transit",
]);

export async function getActiveDelivery(
  client: SupabaseClient,
  driverId: string,
): Promise<RpcResult> {
  const { data, error } = await client
    .from("delivery_assignments")
    .select(
      [
        "id",
        "status",
        "assigned_at",
        "delivery_request_id",
        "delivery_offer_id",
        "bid_id",
        // delivery_offers/bids FK de delivery_assignments (raiz), NÃO de delivery_requests —
        // aninhar sob delivery_requests causa PGRST200 (sem relação). delivery_events/
        // proof_of_delivery FK de delivery_requests → ficam aninhados.
        "delivery_requests(id, status, pickup_address, pickup_latitude, pickup_longitude, pickup_contact_name, pickup_contact_phone, delivery_address, delivery_latitude, delivery_longitude, delivery_contact_name, delivery_contact_phone, vehicle_required, scheduled_at, instructions, notes, assigned_at, picked_up_at, in_transit_at",
        "delivery_quotes(driver_offer_cents, min_driver_offer_cents, max_driver_offer_cents, distance_meters, duration_seconds)",
        "delivery_items(id, description, quantity, weight_g)",
        "delivery_events(id, event_type, actor_type, created_at, metadata)",
        "proof_of_delivery(id, pod_type, created_at))",
        "delivery_offers!delivery_offer_id(driver_offer_cents)",
        "bids!bid_id(bid_amount_cents)",
      ].join(", "),
    )
    .eq("driver_id", driverId)
    .eq("status", "active")
    .is("ended_at", null)
    .order("assigned_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (error) return fail("internal_error");
  if (!data) return ok({ active: null });

  // delivery_requests vem como objeto (1:1 via FK delivery_request_id), não array.
  const req = (data as { delivery_requests?: { status?: string } }).delivery_requests;
  const status = req?.status;
  // assignment ativa mas corrida já terminal? defensive: ignora (deveria ter ended).
  if (!status || !ACTIVE_STATUSES.has(status)) return ok({ active: null });
  return ok({ active: data });
}

// ---- GET /api/driver/deliveries/history ----

export async function getDeliveryHistory(
  client: SupabaseClient,
  driverId: string,
  limit: number,
): Promise<RpcResult> {
  const clamped = Math.max(1, Math.min(50, limit));
  const { data, error } = await client
    .from("delivery_assignments")
    .select(
      [
        "id",
        "status",
        "assigned_at",
        "ended_at",
        "ended_reason",
        // delivery_offers/bids FK da raiz (delivery_assignments), não de delivery_requests.
        "delivery_requests(id, status, pickup_address, delivery_address, delivered_at, cancelled_at, failed_reason, cancelled_reason)",
        "delivery_offers!delivery_offer_id(driver_offer_cents)",
        "bids!bid_id(bid_amount_cents)",
      ].join(", "),
    )
    .eq("driver_id", driverId)
    .not("ended_at", "is", null)
    .order("assigned_at", { ascending: false })
    .limit(clamped);
  if (error) return fail("internal_error");
  return ok({ deliveries: data ?? [] });
}

// ---- GET /api/driver/earnings ----

/** Soma do preço acordado das entregas `delivered` nos últimos 30 dias. */
export async function getEarnings(
  client: SupabaseClient,
  driverId: string,
): Promise<RpcResult> {
  const since = new Date(Date.now() - 30 * 86_400_000).toISOString();
  const { data, error } = await client
    .from("delivery_assignments")
    .select(
      [
        "id",
        "delivery_requests!inner(status, delivered_at)",
        "delivery_offers!delivery_offer_id(driver_offer_cents)",
        "bids!bid_id(bid_amount_cents)",
      ].join(", "),
    )
    .eq("driver_id", driverId)
    .eq("status", "completed")
    .gte("ended_at", since)
    .order("ended_at", { ascending: false })
    .limit(200);
  if (error) return fail("internal_error");

  let totalCents = 0;
  let count = 0;
  for (const row of data ?? []) {
    const r = row as {
      delivery_requests?: { status?: string; delivered_at?: string | null };
      delivery_offers?: { driver_offer_cents?: number | null } | { driver_offer_cents?: number | null }[];
      bids?: { bid_amount_cents?: number | null } | { bid_amount_cents?: number | null }[];
    };
    if (r.delivery_requests?.status !== "delivered") continue;
    const bid = Array.isArray(r.bids) ? r.bids[0] : r.bids;
    const offer = Array.isArray(r.delivery_offers) ? r.delivery_offers[0] : r.delivery_offers;
    const price = bid?.bid_amount_cents ?? offer?.driver_offer_cents ?? 0;
    totalCents += Number(price) || 0;
    count += 1;
  }
  return ok({ total_cents: totalCents, count, period_days: 30 });
}

// ---- POST /api/driver/location ----

/**
 * Upsert de `driver_locations` (telemetria — ADR-023 Fase 3 / D8). Única mutação
 * direta do `authenticated` (RLS `driver_id = my_driver_id()`, 0017). `position`
 * é `geography(Point,4326)` — PostgREST aceita WKT `POINT(lng lat)` (lng primeiro,
 * space-separated; sem vírgula). Sem RPC (regra mestra: telemetria não é estado
 * crítico; bypass explícito em 0015/0017).
 */
export async function upsertDriverLocation(
  client: SupabaseClient,
  driverId: string,
  input: DriverLocationInput,
): Promise<RpcResult> {
  const { error } = await client.from("driver_locations").upsert(
    {
      driver_id: driverId,
      position: `POINT(${input.longitude} ${input.latitude})`,
      accuracy_m: input.accuracyM ?? null,
      heading_deg: input.headingDeg ?? null,
      speed_mps: input.speedMps ?? null,
      captured_at: input.capturedAt,
      received_at: new Date().toISOString(),
    },
    { onConflict: "driver_id" },
  );
  if (error) {
    const reason = String(error.message ?? "").includes("policy")
      ? "not_authorized"
      : "internal_error";
    return { ok: false, reason };
  }
  return ok({ stored: true });
}