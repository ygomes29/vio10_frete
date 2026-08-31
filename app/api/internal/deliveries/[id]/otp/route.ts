import { handleInternalPost } from "@/lib/api/internal-handler";
import { generateOtp } from "@/lib/services/deliveries";

/**
 * `POST /api/internal/deliveries/{id}/otp` → `generate_delivery_otp` (system-only, 5º,
 * ADR-017 D1). **NÃO retorna `otp_code`** (ADR-021 D7 — OTP plaintext nunca sai do
 * backend; redact em first-call E replay). O caminho legítimo de envio é
 * `POST /api/internal/notifications/send {type:'otp'}`, que chama `generateOtp`
 * internamente e envia ao recebedor sem expor o código. Este endpoint gera o OTP
 * (hash em `delivery_otps` + evento `otp_generated`) mas **não** devolve nem envia o
 * plaintext — retido como superfície de geração-only; n8n **não** deve usá-lo
 * (ver ADR-022). **Sensitive**: body não logado (ADR-019 D8).
 */
export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  const { id } = await params;
  return handleInternalPost(request, {
    eventType: "delivery.otp",
    source: "internal-api",
    sensitive: true,
    redact: ["otp_code"],
    run: (correlationId, body) => {
      const b = (body ?? {}) as { ttl_seconds?: number; max_attempts?: number };
      return generateOtp(id, { ttlSeconds: b.ttl_seconds, maxAttempts: b.max_attempts }, correlationId);
    },
  });
}