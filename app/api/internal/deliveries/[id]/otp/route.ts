import { handleInternalPost } from "@/lib/api/internal-handler";
import { generateOtp } from "@/lib/services/deliveries";

/**
 * `POST /api/internal/deliveries/{id}/otp` → `generate_delivery_otp` (system-only, 5º,
 * ADR-017 D1). Retorna o plaintext do OTP **só** ao caller system (internal-auth); n8n
 * encaminha ao recebedor via WhatsApp. **Sensitive**: o corpo da resposta (otp_code)
 * **não** é logado (ADR-019 D8). `ttl_seconds`/`max_attempts` opcionais.
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
    run: (correlationId, body) => {
      const b = (body ?? {}) as { ttl_seconds?: number; max_attempts?: number };
      return generateOtp(id, { ttlSeconds: b.ttl_seconds, maxAttempts: b.max_attempts }, correlationId);
    },
  });
}