import "server-only";
import type { SupabaseClient } from "@supabase/supabase-js";
import { callRpc } from "@/lib/rpc/call";
import type { RpcResult } from "@/lib/rpc/result";

// ---- Tipos de input (contrato ADR-018 D5 / ADR-020 D2) ----

export type RespondOfferInput = {
  offerId: string;
  driverId: string;
  responseType: "accept" | "counter_bid" | "decline";
  bidAmountCents?: number | null;
  idempotencyKey?: string | null;
};

export type SubmitPodInput = {
  deliveryId: string;
  podType: "pickup" | "delivery";
  storagePath?: string | null;
  otpCode?: string | null;
  receiverName?: string | null;
  locationLat?: number | null;
  locationLng?: number | null;
  notes?: string | null;
};

export type TransitionDriverInput = {
  toStatus: "driver_to_pickup" | "at_pickup" | "picked_up" | "in_transit";
  metadata?: Record<string, unknown> | null;
};

export type AvailabilityInput = {
  driverId: string;
  status: "available" | "paused" | "offline";
  reason?: string | null;
};

export type ValidationResult = { valid: true } | { valid: false; reason: string };

// ---- Validators (puros, unit-testáveis) ----

export function validateRespondOfferBody(body: unknown): ValidationResult {
  if (!body || typeof body !== "object") return { valid: false, reason: "invalid_param" };
  const b = body as Record<string, unknown>;
  if (typeof b.driver_id !== "string" || !b.driver_id) return { valid: false, reason: "invalid_param" };
  const rt = b.response_type;
  if (rt !== "accept" && rt !== "counter_bid" && rt !== "decline") {
    return { valid: false, reason: "invalid_response_type" };
  }
  if (rt === "counter_bid") {
    const amt = b.bid_amount_cents;
    if (typeof amt !== "number" || !Number.isFinite(amt) || amt <= 0) {
      return { valid: false, reason: "invalid_bid_amount" };
    }
  }
  return { valid: true };
}

export function validatePodBody(body: unknown): ValidationResult {
  if (!body || typeof body !== "object") return { valid: false, reason: "invalid_param" };
  const b = body as Record<string, unknown>;
  if (b.pod_type !== "pickup" && b.pod_type !== "delivery") {
    return { valid: false, reason: "invalid_pod" };
  }
  if (b.pod_type === "delivery") {
    // delivery exige (foto OU otp) E receiver_name
    if ((typeof b.storage_path !== "string" || !b.storage_path) &&
        (typeof b.otp_code !== "string" || !b.otp_code)) {
      return { valid: false, reason: "invalid_pod" };
    }
    if (typeof b.receiver_name !== "string" || !b.receiver_name) {
      return { valid: false, reason: "invalid_pod" };
    }
  } else {
    // pickup exige ao menos um de storage_path/otp_code/notes
    if ((typeof b.storage_path !== "string" || !b.storage_path) &&
        (typeof b.otp_code !== "string" || !b.otp_code) &&
        (typeof b.notes !== "string" || !b.notes)) {
      return { valid: false, reason: "invalid_pod" };
    }
  }
  if (b.location_lat !== undefined && b.location_lat !== null) {
    if (typeof b.location_lat !== "number" || !Number.isFinite(b.location_lat)) {
      return { valid: false, reason: "invalid_param" };
    }
  }
  if (b.location_lng !== undefined && b.location_lng !== null) {
    if (typeof b.location_lng !== "number" || !Number.isFinite(b.location_lng)) {
      return { valid: false, reason: "invalid_param" };
    }
  }
  return { valid: true };
}

const DRIVER_TRANSITIONS = new Set(["driver_to_pickup", "at_pickup", "picked_up", "in_transit"]);

export function validateTransitionBody(body: unknown): ValidationResult {
  if (!body || typeof body !== "object") return { valid: false, reason: "invalid_param" };
  const b = body as Record<string, unknown>;
  if (typeof b.to_status !== "string" || !DRIVER_TRANSITIONS.has(b.to_status)) {
    return { valid: false, reason: "invalid_transition" };
  }
  if (b.metadata !== undefined && b.metadata !== null) {
    if (typeof b.metadata !== "object") return { valid: false, reason: "invalid_param" };
  }
  return { valid: true };
}

const DRIVER_SELF_STATUSES = new Set(["available", "paused", "offline"]);

export function validateAvailabilityBody(body: unknown): ValidationResult {
  if (!body || typeof body !== "object") return { valid: false, reason: "invalid_param" };
  const b = body as Record<string, unknown>;
  // driver_id é injetado pelo handler (resolve de auth.uid), não do body — opcional aqui.
  if (b.driver_id !== undefined && (typeof b.driver_id !== "string" || !b.driver_id)) {
    return { valid: false, reason: "invalid_param" };
  }
  if (typeof b.status !== "string" || !DRIVER_SELF_STATUSES.has(b.status)) {
    // offered/busy são setados pelo sistema (dispatch), não pelo driver.
    return { valid: false, reason: "invalid_param" };
  }
  if (b.reason !== undefined && b.reason !== null && typeof b.reason !== "string") {
    return { valid: false, reason: "invalid_param" };
  }
  return { valid: true };
}

// ---- Resolução de driver (user-scoped) ----

/**
 * Resolve o `drivers.id` a partir do `user_id` (auth.uid). O client deve ser
 * user-scoped (cookie JWT) — RLS deixa o driver ver a própria linha. Retorna
 * `null` se o usuário não é driver.
 */
export async function resolveDriverId(
  client: SupabaseClient,
  userId: string,
): Promise<string | null> {
  const { data, error } = await client
    .from("drivers")
    .select("id")
    .eq("user_id", userId)
    .maybeSingle();
  if (error || !data) return null;
  return (data as { id: string }).id ?? null;
}

// ---- Service fns (client-agnostic — handler decide user vs system scope) ----

/**
 * `POST /api/offers/{id}/respond` → `respond_to_offer` (ADR-020 D1).
 * Idempotência **interna** da RPC (`bids.idempotency_key` + `(offer,driver)` unique).
 * Não atribui (ACEITAR ≠ GANHAR, ADR-006).
 */
export async function respondToOffer(
  client: SupabaseClient,
  input: RespondOfferInput,
  correlationId: string,
): Promise<RpcResult> {
  return callRpc(client, "respond_to_offer", {
    p_delivery_offer_id: input.offerId,
    p_driver_id: input.driverId,
    p_response_type: input.responseType,
    p_bid_amount_cents: input.bidAmountCents ?? null,
    p_idempotency_key: input.idempotencyKey ?? null,
    p_correlation_id: correlationId,
  });
}

/**
 * `POST /api/driver/deliveries/{id}/pod` → `submit_proof_of_delivery` (driver-scoped).
 * **Não transita** (emite `pod_submitted`; a transição `delivered` é system via
 * `confirm_delivery`). OTP validado atomicamente (for update) quando `otp_code` presente.
 */
export async function submitProofOfDelivery(
  client: SupabaseClient,
  input: SubmitPodInput,
  correlationId: string,
): Promise<RpcResult> {
  return callRpc(client, "submit_proof_of_delivery", {
    p_delivery_request_id: input.deliveryId,
    p_pod_type: input.podType,
    p_storage_path: input.storagePath ?? null,
    p_otp_code: input.otpCode ?? null,
    p_receiver_name: input.receiverName ?? null,
    p_location_lat: input.locationLat ?? null,
    p_location_lng: input.locationLng ?? null,
    p_notes: input.notes ?? null,
    p_correlation_id: correlationId,
  });
}

/**
 * `POST /api/driver/deliveries/{id}/transitions` → `transition_delivery` (driver path).
 * A RPC resolve o ator de `auth.uid()` (driver c/ assignment ativa) e ignora
 * `p_actor_type`/`p_actor_id` no path user-scoped. Passamos `p_actor_type='driver'`
 * só p/ documentar intent (a RPC sobrescreve). Driver só as 4 transições (ADR-016 D1).
 */
export async function transitionDeliveryDriver(
  client: SupabaseClient,
  deliveryId: string,
  input: TransitionDriverInput,
  correlationId: string,
): Promise<RpcResult> {
  return callRpc(client, "transition_delivery", {
    p_delivery_request_id: deliveryId,
    p_to_status: input.toStatus,
    p_actor_type: "driver",
    p_actor_id: null,
    p_metadata: input.metadata ?? null,
    p_correlation_id: correlationId,
  });
}

/**
 * `POST /api/driver/availability` → `set_driver_availability` (driver-scoped).
 * Esta RPC retorna `void` e **raise exception** `'not_authorized'` (não segue o
 * padrão `returns table(ok,reason)`); logo não usa `callRpc`. Mapeia a exception
 * p/ `{ok:false, reason:'not_authorized'}` (→ 403 via `reasonToStatus`).
 */
export async function setDriverAvailability(
  client: SupabaseClient,
  input: AvailabilityInput,
): Promise<RpcResult> {
  const { error } = await client.rpc("set_driver_availability", {
    p_driver_id: input.driverId,
    p_status: input.status,
    p_reason: input.reason ?? null,
  });
  if (error) {
    const reason = String(error.message ?? "").includes("not_authorized")
      ? "not_authorized"
      : "internal_error";
    return { ok: false, reason };
  }
  return { ok: true, reason: null };
}