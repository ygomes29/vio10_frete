import { handleInternalPost } from "@/lib/api/internal-handler";
import { createSystemClient } from "@/lib/supabase/system-client";
import {
  sendNotification,
  validateSendNotificationBody,
  type SendNotificationInput,
} from "@/lib/services/notifications";

/**
 * `POST /api/internal/notifications/send` (system, `x-internal-api-key`, ADR-021 D2).
 * Backend resolve destinatário, escolhe provider (híbrido D1), envia WhatsApp e loga
 * em `notifications`. n8n/IA/DataCrazy **não** enviam direto — chamam este endpoint.
 *
 * Body: `{type:'offer'|'otp'|'assignment'|'status_update'|'terminal', offer_id?, delivery_id?}`.
 *  - `offer`      → resolve offer+driver, gera signed link (sem PII do cliente), envia ao driver.
 *  - `otp`        → chama `generate_delivery_otp` **internamente** (plaintext NÃO sai do backend),
 *                   envia ao recebedor (delivery_contact_phone). Response `{ok, reason}` sem `otp_code`.
 *  - `assignment` → resolve assignment ativa + PII (pós-atribuição), envia ao driver.
 *  - `status_update`/`terminal` → envia ao contato de coleta (business).
 *
 * Idempotência: handler ledger (`withIdempotency`) + `notifications.idempotency_key` (determinística).
 * Sem provider WhatsApp configurado → 501 `whatsapp_provider_not_configured` (ADR-021 D1).
 */
export async function POST(request: Request): Promise<Response> {
  return handleInternalPost(request, {
    eventType: "notification.send",
    source: "internal-api",
    validate: (b) => {
      const r = validateSendNotificationBody(b);
      return r.valid ? null : r.reason;
    },
    run: (correlationId, body) => {
      const client = createSystemClient();
      const input = body as SendNotificationInput;
      return sendNotification(client, input, correlationId);
    },
  });
}