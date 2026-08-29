import "server-only";
import { createSystemClient } from "@/lib/supabase/system-client";
import { callRpc } from "@/lib/rpc/call";
import type { RpcResult } from "@/lib/rpc/result";

// ---- Tipos de input (contrato ADR-018 D5) ----

export type CreateDeliveryInput = {
  organization_id: string;
  business_id: string;
  business_location_id: string;
  pickup_address: string;
  pickup_lat: number;
  pickup_lng: number;
  pickup_contact_name?: string;
  pickup_contact_phone?: string;
  delivery_address: string;
  delivery_lat: number;
  delivery_lng: number;
  delivery_contact_name?: string;
  delivery_contact_phone?: string;
  vehicle_required: "motorcycle" | "car";
  priority?: "standard" | "urgent";
  scheduled_at?: string | null;
  origin: "dashboard" | "whatsapp" | "api" | "operator" | "integration";
  external_reference: string;
  notes?: string | null;
  instructions?: string | null;
  items: Array<{ description: string; quantity: number }>;
};

export type ValidationResult = { valid: true } | { valid: false; reason: string };

/** Validador puro de input de criação (unit-testável). */
export function validateCreateDelivery(body: unknown): ValidationResult {
  if (!body || typeof body !== "object") return { valid: false, reason: "invalid_param" };
  const b = body as Partial<CreateDeliveryInput> & Record<string, unknown>;
  const required: Array<keyof CreateDeliveryInput> = [
    "organization_id", "business_id", "business_location_id",
    "pickup_address", "pickup_lat", "pickup_lng",
    "delivery_address", "delivery_lat", "delivery_lng",
    "vehicle_required", "origin", "external_reference", "items",
  ];
  for (const k of required) {
    if (b[k] === undefined || b[k] === null || b[k] === "") {
      return { valid: false, reason: "invalid_param" };
    }
  }
  if (b.vehicle_required !== "motorcycle" && b.vehicle_required !== "car") {
    return { valid: false, reason: "invalid_param" };
  }
  if (
    b.origin !== "dashboard" && b.origin !== "whatsapp" && b.origin !== "api" &&
    b.origin !== "operator" && b.origin !== "integration"
  ) {
    return { valid: false, reason: "invalid_param" };
  }
  if (b.priority && b.priority !== "standard" && b.priority !== "urgent") {
    return { valid: false, reason: "invalid_param" };
  }
  if (!Array.isArray(b.items) || b.items.length === 0) {
    return { valid: false, reason: "invalid_param" };
  }
  for (const it of b.items) {
    if (!it || typeof it !== "object") return { valid: false, reason: "invalid_param" };
    const item = it as { description?: unknown; quantity?: unknown };
    if (typeof item.description !== "string" || !item.description ||
        typeof item.quantity !== "number" || item.quantity <= 0) {
      return { valid: false, reason: "invalid_param" };
    }
  }
  return { valid: true };
}

/**
 * `POST /api/internal/deliveries` → `create_delivery_request` (user-or-system).
 * Cria em `draft` + itens + evento `delivery_created`; **sem preço** (ADR-011).
 * Dedup de criação por `external_reference` é interna da RPC (on conflict 0021:140).
 */
export async function createDelivery(
  input: CreateDeliveryInput,
  correlationId: string,
): Promise<RpcResult> {
  const client = createSystemClient();
  return callRpc(client, "create_delivery_request", {
    p_organization_id: input.organization_id,
    p_business_id: input.business_id,
    p_business_location_id: input.business_location_id,
    p_pickup_address: input.pickup_address,
    p_pickup_lat: input.pickup_lat,
    p_pickup_lng: input.pickup_lng,
    p_pickup_contact_name: input.pickup_contact_name ?? null,
    p_pickup_contact_phone: input.pickup_contact_phone ?? null,
    p_delivery_address: input.delivery_address,
    p_delivery_lat: input.delivery_lat,
    p_delivery_lng: input.delivery_lng,
    p_delivery_contact_name: input.delivery_contact_name ?? null,
    p_delivery_contact_phone: input.delivery_contact_phone ?? null,
    p_vehicle_required: input.vehicle_required,
    p_priority: input.priority ?? "standard",
    p_scheduled_at: input.scheduled_at ?? null,
    p_origin: input.origin,
    p_external_reference: input.external_reference,
    p_notes: input.notes ?? null,
    p_instructions: input.instructions ?? null,
    p_items: input.items,
    p_correlation_id: correlationId,
  });
}

/** `POST /api/internal/deliveries/{id}/confirm-quote` → `confirm_quote` (user-or-system). */
export async function confirmQuote(deliveryId: string, correlationId: string): Promise<RpcResult> {
  const client = createSystemClient();
  return callRpc(client, "confirm_quote", {
    p_delivery_request_id: deliveryId,
    p_correlation_id: correlationId,
  });
}

/**
 * `POST /api/internal/deliveries/{id}/otp` → `generate_delivery_otp` (system-only, 5º).
 * Retorna o plaintext do OTP **só** ao caller system (internal-auth) — n8n encaminha ao
 * recebedor via WhatsApp. **Nunca logar otp_code** (ADR-017 D1, ADR-019 D8).
 */
export async function generateOtp(
  deliveryId: string,
  opts: { ttlSeconds?: number; maxAttempts?: number },
  correlationId: string,
): Promise<RpcResult> {
  const client = createSystemClient();
  return callRpc(client, "generate_delivery_otp", {
    p_delivery_request_id: deliveryId,
    p_ttl_seconds: opts.ttlSeconds ?? 900,
    p_max_attempts: opts.maxAttempts ?? 5,
    p_correlation_id: correlationId,
  });
}

/** `POST /api/internal/deliveries/{id}/confirm` → `confirm_delivery` (system-only). */
export async function confirmDelivery(
  deliveryId: string,
  opts: { geoToleranceM?: number },
  correlationId: string,
): Promise<RpcResult> {
  const client = createSystemClient();
  return callRpc(client, "confirm_delivery", {
    p_delivery_request_id: deliveryId,
    p_geo_tolerance_m: opts.geoToleranceM ?? null,
    p_correlation_id: correlationId,
  });
}

/**
 * `POST /api/internal/deliveries/{id}/transitions` (path **system**; path driver → Sessão 15).
 * → `transition_delivery` (matriz ator×transição ADR-016). Atributo `actor_type='system'`.
 */
export async function transitionDeliverySystem(
  deliveryId: string,
  opts: { toStatus: string; metadata?: Record<string, unknown> | null },
  correlationId: string,
): Promise<RpcResult> {
  const client = createSystemClient();
  return callRpc(client, "transition_delivery", {
    p_delivery_request_id: deliveryId,
    p_to_status: opts.toStatus,
    p_actor_type: "system",
    p_actor_id: null,
    p_metadata: opts.metadata ?? null,
    p_correlation_id: correlationId,
  });
}