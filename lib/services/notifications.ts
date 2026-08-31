import "server-only";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { RpcResult } from "@/lib/rpc/result";
import { createActionLink } from "@/lib/auth/signed-link";
import { generateOtp } from "./deliveries";
import { ensureWhatsAppProviderRegistered } from "@/lib/providers/whatsapp-registration";
import { getWhatsAppProvider, WhatsAppProviderNotConfiguredError } from "@/lib/providers/whatsapp-provider";
import { logEvent } from "@/lib/api/http";

// ---- Tipos (contrato ADR-021 D2) ----

export type NotificationType = "offer" | "otp" | "assignment" | "status_update" | "terminal";

export type SendNotificationInput = {
  type: NotificationType;
  offer_id?: string;   // type='offer'
  delivery_id?: string; // demais types
};

export type ValidationResult = { valid: true } | { valid: false; reason: string };

const ALLOWED_TYPES: NotificationType[] = ["offer", "otp", "assignment", "status_update", "terminal"];

/** Validador puro do body de `/api/internal/notifications/send` (unit-testável). */
export function validateSendNotificationBody(body: unknown): ValidationResult {
  if (!body || typeof body !== "object") return { valid: false, reason: "invalid_param" };
  const b = body as Record<string, unknown>;
  if (typeof b.type !== "string" || !ALLOWED_TYPES.includes(b.type as NotificationType)) {
    return { valid: false, reason: "invalid_param" };
  }
  if (b.type === "offer") {
    if (typeof b.offer_id !== "string" || !b.offer_id) return { valid: false, reason: "invalid_param" };
  } else {
    if (typeof b.delivery_id !== "string" || !b.delivery_id) return { valid: false, reason: "invalid_param" };
  }
  return { valid: true };
}

// ---- Helpers de formatação ----

/** centavos → "R$ 10,90" (inteiros, nunca float — regra mestra). */
function formatBRL(cents: number): string {
  const reais = Math.floor(cents / 100);
  const centavos = cents % 100;
  return `R$ ${reais},${centavos.toString().padStart(2, "0")}`;
}

const VEHICLE_LABEL: Record<string, string> = { motorcycle: "moto", car: "carro" };
const PRIORITY_LABEL: Record<string, string> = { standard: "padrão", urgent: "urgente" };
const STATUS_LABEL: Record<string, string> = {
  draft: "rascunho", quoted: "cotada", searching_driver: "buscando entregador",
  assigned: "entregador atribuído", driver_to_pickup: "a caminho da coleta",
  at_pickup: "no local de coleta", picked_up: "pedido coletado",
  in_transit: "em trânsito", delivered: "entregue",
  cancelled: "cancelada", failed: "falhou", expired: "expirada",
};

// ---- Resolução de destinatário + mensagem (queries via client system) ----

type OfferCtx = {
  driverId: string;
  driverPhone: string;
  driverOfferCents: number;
  deliveryId: string;
  expiresAt: string;
  vehicleRequired: string;
  priority: string;
};

async function resolveOfferContext(client: SupabaseClient, offerId: string): Promise<OfferCtx | null> {
  const { data: offer } = await client
    .from("delivery_offers")
    .select("driver_id, driver_offer_cents, delivery_request_id, expires_at")
    .eq("id", offerId)
    .maybeSingle();
  if (!offer) return null;
  const o = offer as {
    driver_id: string; driver_offer_cents: number;
    delivery_request_id: string; expires_at: string;
  };
  const { data: drv } = await client
    .from("drivers")
    .select("phone")
    .eq("id", o.driver_id)
    .maybeSingle();
  const { data: del } = await client
    .from("delivery_requests")
    .select("vehicle_required, priority")
    .eq("id", o.delivery_request_id)
    .maybeSingle();
  if (!drv || !del) return null;
  return {
    driverId: o.driver_id,
    driverPhone: (drv as { phone: string }).phone,
    driverOfferCents: o.driver_offer_cents,
    deliveryId: o.delivery_request_id,
    expiresAt: o.expires_at,
    vehicleRequired: (del as { vehicle_required: string }).vehicle_required,
    priority: (del as { priority: string }).priority,
  };
}

type DeliveryCtx = {
  id: string;
  status: string;
  vehicle_required: string;
  pickup_address: string;
  pickup_contact_name: string | null;
  pickup_contact_phone: string;
  delivery_address: string;
  delivery_contact_name: string | null;
  delivery_contact_phone: string;
};

async function resolveDeliveryContext(client: SupabaseClient, deliveryId: string): Promise<DeliveryCtx | null> {
  const { data } = await client
    .from("delivery_requests")
    .select("id, status, vehicle_required, pickup_address, pickup_contact_name, pickup_contact_phone, delivery_address, delivery_contact_name, delivery_contact_phone")
    .eq("id", deliveryId)
    .maybeSingle();
  if (!data) return null;
  return data as DeliveryCtx | null;
}

async function resolveAssignedDriverPhone(client: SupabaseClient, deliveryId: string): Promise<{ driverId: string; phone: string } | null> {
  const { data: ass } = await client
    .from("delivery_assignments")
    .select("driver_id")
    .eq("delivery_request_id", deliveryId)
    .eq("status", "active")
    .maybeSingle();
  if (!ass) return null;
  const driverId = (ass as { driver_id: string }).driver_id;
  const { data: drv } = await client
    .from("drivers")
    .select("phone")
    .eq("id", driverId)
    .maybeSingle();
  if (!drv) return null;
  return { driverId, phone: (drv as { phone: string }).phone };
}

// ---- Log em notifications (idempotente por idempotency_key UNIQUE) ----

type NotifRow = {
  recipient_user_id?: string | null;
  recipient_driver_id?: string | null;
  recipient_phone?: string | null;
  event_type: string;
  template: string;
  provider: string;
  external_id?: string | null;
  status: string;
  idempotency_key: string;
  attempts: number;
  payload: Record<string, unknown>;
};

async function logNotification(client: SupabaseClient, row: NotifRow): Promise<void> {
  // onConflict idempotency_key + ignoreDuplicates → replay não duplica row.
  await client.from("notifications").upsert(
    {
      recipient_user_id: row.recipient_user_id ?? null,
      recipient_driver_id: row.recipient_driver_id ?? null,
      recipient_phone: row.recipient_phone ?? null,
      channel: "whatsapp",
      event_type: row.event_type,
      template: row.template,
      provider: row.provider,
      external_id: row.external_id ?? null,
      status: row.status,
      idempotency_key: row.idempotency_key,
      attempts: row.attempts,
      payload: row.payload,
      sent_at: new Date().toISOString(),
    },
    { onConflict: "idempotency_key", ignoreDuplicates: true },
  );
}

// ---- Service principal ----

/**
 * `POST /api/internal/notifications/send` (system, ADR-021 D2). Backend resolve
 * destinatário, escolhe provider (híbrido D1), envia e loga em `notifications`.
 * n8n/IA/DataCrazy **não** enviam direto — chamam este endpoint.
 *
 * PII (ADR-018 D10): mensagem `type:'offer'` **sem PII do cliente** (pré-atribuição);
 * `type:'assignment'` libera PII (endereços/contatos — pós-atribuição).
 * **OTP plaintext nunca sai do backend**: `type:'otp'` chama `generate_delivery_otp`
 * internamente, envia o código ao recebedor, e retorna `{ok, reason}` **sem `otp_code`**.
 * `notifications.payload` guarda só metadados (correlation, type, recipient_role) —
 * nunca o código OTP nem secrets.
 */
export async function sendNotification(
  client: SupabaseClient,
  input: SendNotificationInput,
  correlationId: string,
): Promise<RpcResult> {
  ensureWhatsAppProviderRegistered();
  const provider = getWhatsAppProvider();
  if (!provider) throw new WhatsAppProviderNotConfiguredError();

  switch (input.type) {
    case "offer":
      return sendOffer(client, provider, input, correlationId);
    case "otp":
      return sendOtp(client, provider, input, correlationId);
    case "assignment":
      return sendAssignment(client, provider, input, correlationId);
    case "status_update":
      return sendStatusUpdate(client, provider, input, correlationId);
    case "terminal":
      return sendTerminal(client, provider, input, correlationId);
    default:
      return { ok: false, reason: "invalid_param" };
  }
}

async function sendOffer(
  client: SupabaseClient,
  provider: ReturnType<typeof getWhatsAppProvider> & {},
  input: SendNotificationInput,
  correlationId: string,
): Promise<RpcResult> {
  const offerId = input.offer_id!;
  const ctx = await resolveOfferContext(client, offerId);
  if (!ctx) return { ok: false, reason: "not_found" };

  // Signed link (TTL = restante até offer expirar, clamp 60..900).
  const remainingMs = new Date(ctx.expiresAt).getTime() - Date.now();
  const ttlSeconds = Math.max(60, Math.min(900, Math.floor(remainingMs / 1000)));
  const link = createActionLink({ offerId, driverId: ctx.driverId, ttlSeconds });
  const base = process.env.NEXT_PUBLIC_APP_URL ?? "";
  const url = `${base}/api/offers/${offerId}/respond?token=${link.token}`;

  // PII-FREE (pré-atribuição): sem endereços/contatos do cliente.
  const body =
    `ViO10 — Nova oportunidade de corrida!\n` +
    `Valor: ${formatBRL(ctx.driverOfferCents)}\n` +
    `Veículo: ${VEHICLE_LABEL[ctx.vehicleRequired] ?? ctx.vehicleRequired} · ` +
    `Prioridade: ${PRIORITY_LABEL[ctx.priority] ?? ctx.priority}\n` +
    `Responda: ${url}`;

  const result = await provider.send({ to: ctx.driverPhone, body });
  await logNotification(client, {
    recipient_driver_id: ctx.driverId,
    event_type: "offer",
    template: "offer",
    provider: result.provider,
    external_id: result.externalId,
    status: result.ok ? "sent" : "failed",
    idempotency_key: `notif:offer:${offerId}`,
    attempts: 1,
    payload: { correlation_id: correlationId, type: "offer", recipient_role: "driver", offer_id: offerId, delivery_id: ctx.deliveryId },
  });
  logEvent({ correlation_id: correlationId, event: "notification.offer", ok: result.ok, provider: result.provider });
  return { ok: true, reason: null, notification_provider: result.provider };
}

async function sendOtp(
  client: SupabaseClient,
  provider: ReturnType<typeof getWhatsAppProvider> & {},
  input: SendNotificationInput,
  correlationId: string,
): Promise<RpcResult> {
  const deliveryId = input.delivery_id!;
  // 1. Gera OTP internamente (system). otp_code plaintext fica AQUI, não vaza.
  const otpResult = await generateOtp(deliveryId, {}, correlationId);
  if (!otpResult.ok) return otpResult; // reason do generate_delivery_otp (otp_not_generated, etc.)
  const otpCode = (otpResult as { otp_code?: string }).otp_code;
  if (!otpCode) return { ok: false, reason: "otp_not_generated" };

  // 2. Resolve telefone do recebedor.
  const del = await resolveDeliveryContext(client, deliveryId);
  if (!del) return { ok: false, reason: "delivery_not_found" };

  // 3. Monta + envia. otpCode NÃO é logado.
  const body = `ViO10 — Seu código de entrega: ${otpCode}`;
  const result = await provider.send({ to: del.delivery_contact_phone, body });

  await logNotification(client, {
    recipient_phone: del.delivery_contact_phone,
    event_type: "otp",
    template: "otp",
    provider: result.provider,
    external_id: result.externalId,
    status: result.ok ? "sent" : "failed",
    idempotency_key: `notif:otp:${deliveryId}`,
    attempts: 1,
    // payload: só metadados — NUNCA otp_code.
    payload: { correlation_id: correlationId, type: "otp", recipient_role: "receiver", delivery_id: deliveryId },
  });
  logEvent({ correlation_id: correlationId, event: "notification.otp", ok: result.ok, provider: result.provider });
  // Response SEM otp_code (plaintext nunca sai do backend).
  return { ok: true, reason: null, notification_provider: result.provider };
}

async function sendAssignment(
  client: SupabaseClient,
  provider: ReturnType<typeof getWhatsAppProvider> & {},
  input: SendNotificationInput,
  correlationId: string,
): Promise<RpcResult> {
  const deliveryId = input.delivery_id!;
  const del = await resolveDeliveryContext(client, deliveryId);
  if (!del) return { ok: false, reason: "delivery_not_found" };
  const drv = await resolveAssignedDriverPhone(client, deliveryId);
  if (!drv) return { ok: false, reason: "not_found" }; // sem assignment ativa

  // Pós-atribuição: PII liberada (endereços/contatos).
  const body =
    `ViO10 — Corrida atribuída a você!\n` +
    `Coleta: ${del.pickup_address}\n` + (del.pickup_contact_name ? `Contato coleta: ${del.pickup_contact_name} ${del.pickup_contact_phone}\n` : "") +
    `Entrega: ${del.delivery_address}\n` + (del.delivery_contact_name ? `Contato entrega: ${del.delivery_contact_name} ${del.delivery_contact_phone}\n` : "") +
    `Veículo: ${VEHICLE_LABEL[del.vehicle_required] ?? del.vehicle_required}`;

  const result = await provider.send({ to: drv.phone, body });
  await logNotification(client, {
    recipient_driver_id: drv.driverId,
    event_type: "assignment",
    template: "assignment",
    provider: result.provider,
    external_id: result.externalId,
    status: result.ok ? "sent" : "failed",
    idempotency_key: `notif:assignment:${deliveryId}`,
    attempts: 1,
    payload: { correlation_id: correlationId, type: "assignment", recipient_role: "driver", delivery_id: deliveryId },
  });
  logEvent({ correlation_id: correlationId, event: "notification.assignment", ok: result.ok, provider: result.provider });
  return { ok: true, reason: null, notification_provider: result.provider };
}

async function sendStatusUpdate(
  client: SupabaseClient,
  provider: ReturnType<typeof getWhatsAppProvider> & {},
  input: SendNotificationInput,
  correlationId: string,
): Promise<RpcResult> {
  const deliveryId = input.delivery_id!;
  const del = await resolveDeliveryContext(client, deliveryId);
  if (!del) return { ok: false, reason: "delivery_not_found" };

  const label = STATUS_LABEL[del.status] ?? del.status;
  const body = `ViO10 — Atualização da corrida ${deliveryId.slice(0, 8)}: ${label}.`;
  const result = await provider.send({ to: del.pickup_contact_phone, body });
  await logNotification(client, {
    recipient_phone: del.pickup_contact_phone,
    event_type: "status_update",
    template: "status_update",
    provider: result.provider,
    external_id: result.externalId,
    status: result.ok ? "sent" : "failed",
    idempotency_key: `notif:status_update:${deliveryId}:${del.status}`,
    attempts: 1,
    payload: { correlation_id: correlationId, type: "status_update", recipient_role: "business", delivery_id: deliveryId, status: del.status },
  });
  logEvent({ correlation_id: correlationId, event: "notification.status_update", ok: result.ok, provider: result.provider });
  return { ok: true, reason: null, notification_provider: result.provider };
}

async function sendTerminal(
  client: SupabaseClient,
  provider: ReturnType<typeof getWhatsAppProvider> & {},
  input: SendNotificationInput,
  correlationId: string,
): Promise<RpcResult> {
  const deliveryId = input.delivery_id!;
  const del = await resolveDeliveryContext(client, deliveryId);
  if (!del) return { ok: false, reason: "delivery_not_found" };

  const label = STATUS_LABEL[del.status] ?? del.status;
  const body = `ViO10 — Corrida ${deliveryId.slice(0, 8)} ${label}.`;
  const result = await provider.send({ to: del.pickup_contact_phone, body });
  await logNotification(client, {
    recipient_phone: del.pickup_contact_phone,
    event_type: "terminal",
    template: "terminal",
    provider: result.provider,
    external_id: result.externalId,
    status: result.ok ? "sent" : "failed",
    idempotency_key: `notif:terminal:${deliveryId}:${del.status}`,
    attempts: 1,
    payload: { correlation_id: correlationId, type: "terminal", recipient_role: "business", delivery_id: deliveryId, status: del.status },
  });
  logEvent({ correlation_id: correlationId, event: "notification.terminal", ok: result.ok, provider: result.provider });
  return { ok: true, reason: null, notification_provider: result.provider };
}