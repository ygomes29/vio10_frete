import { handleInternalPost } from "@/lib/api/internal-handler";
import { createSystemClient } from "@/lib/supabase/system-client";
import { scanReconciler, validateScanBody, type ScanInput } from "@/lib/services/reconciler";

/**
 * `POST /api/internal/reconciler/scan` (system, `x-internal-api-key`, ADR-021).
 * **Read-only**: retorna achados stale p/ o n8n (Schedule Trigger) reprocessar chamando
 * Route Handlers. n8n não query o DB direto (regra mestra).
 *
 * Body (opcional): `{stale_after_seconds?}` (default 300 — janela p/ considerar draft stale).
 *
 * **Sem `Idempotency-Key`**: o caller NÃO envia a key → ledger `skip` → re-query sempre
 * (cachear um scan seria stale). Retornar o resultado cacheado de um scan anterior seria
 * incorreto p/ um reconciler.
 */
export async function POST(request: Request): Promise<Response> {
  return handleInternalPost(request, {
    eventType: "reconciler.scan",
    source: "internal-api",
    validate: (b) => {
      const r = validateScanBody(b);
      return r.valid ? null : r.reason;
    },
    run: (_correlationId, body) => {
      const client = createSystemClient();
      const input: ScanInput = (body ?? {}) as ScanInput;
      return scanReconciler(client, input);
    },
  });
}