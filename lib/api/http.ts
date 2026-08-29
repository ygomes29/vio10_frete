import "server-only";
import { verifyInternalApiKey, getInternalApiKey } from "@/lib/supabase/internal-auth";

/** Resposta JSON com status. */
export function jsonResponse(status: number, body: Record<string, unknown>): Response {
  return Response.json(body, { status });
}

/**
 * Guarda de auth interna para system-callers (n8n). Retorna uma Response 401 se
 * falhar, ou `null` se autorizado (ADR-019 D3). Uso:
 *   const fail = requireInternal(request); if (fail) return fail;
 */
export function requireInternal(request: Request): Response | null {
  if (!verifyInternalApiKey(getInternalApiKey(request))) {
    return jsonResponse(401, { ok: false, reason: "not_authorized" });
  }
  return null;
}

/** correlation_id end-to-end (ADR-018 D10): header ou gerado. */
export function getCorrelationId(request: Request): string {
  const h = request.headers.get("x-correlation-id");
  if (h) return h;
  return crypto.randomUUID();
}

/** Headers de idempotência (R17 — ADR-019 D4). */
export function getIdempotencyHeaders(request: Request): {
  idempotencyKey: string | null;
  externalEventId: string | null;
} {
  return {
    idempotencyKey: request.headers.get("idempotency-key"),
    externalEventId: request.headers.get("x-external-event-id"),
  };
}

/** Log estruturado sem secrets/PII (ADR-019 D8). */
export function logEvent(fields: Record<string, unknown>): void {
  // Nunca logar service_role, INTERNAL_API_KEY, plaintext OTP. O caller filtra.
  console.log(JSON.stringify(fields));
}