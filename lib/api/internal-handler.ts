import "server-only";
import { requireInternal, jsonResponse, getCorrelationId, getIdempotencyHeaders, logEvent } from "./http";
import { createSystemClient } from "@/lib/supabase/system-client";
import { withIdempotency, InFlightError } from "@/lib/idempotency/ledger";
import { toApiResponse, reasonToStatus } from "@/lib/rpc/result";
import type { RpcResult } from "@/lib/rpc/result";

type HandlerOpts = {
  eventType: string;
  source?: string;
  /** Validação pré-claim (roda ANTES do ledger — falha não vira replay). Retorna reason ou null. */
  validate?: (body: unknown) => string | null;
  /** Executa a operação (chama a RPC). Recebe o correlation_id e o body parseado. */
  run: (correlationId: string, body: unknown) => Promise<RpcResult>;
  /** Se true, não loga o body nem o resultado detalhado (ex.: OTP — ADR-019 D8). */
  sensitive?: boolean;
};

/**
 * Fluxo padrão dos Route Handlers system/internal (ADR-019 D1):
 *   internal-auth → parse JSON → validate (pré-claim) → idempotency ledger → RPC → map → HTTP.
 * `service_role` nunca vaza; o caller (n8n) autentica por `x-internal-api-key`.
 */
export async function handleInternalPost(request: Request, opts: HandlerOpts): Promise<Response> {
  const fail = requireInternal(request);
  if (fail) return fail;

  const correlationId = getCorrelationId(request);
  const { idempotencyKey, externalEventId } = getIdempotencyHeaders(request);

  let body: unknown = null;
  try {
    const text = await request.text();
    if (text.trim() !== "") body = JSON.parse(text);
  } catch {
    return jsonResponse(400, { ok: false, reason: "invalid_param", detail: "body json inválido", correlation_id: correlationId });
  }

  if (opts.validate) {
    const reason = opts.validate(body);
    if (reason) {
      return jsonResponse(reasonToStatus(reason), { ok: false, reason, correlation_id: correlationId });
    }
  }

  const client = createSystemClient();
  try {
    const result = await withIdempotency(
      client,
      {
        source: opts.source ?? "internal-api",
        idempotencyKey,
        externalEventId,
        eventType: opts.eventType,
        payload: opts.sensitive ? null : (body as Record<string, unknown> | null),
      },
      () => opts.run(correlationId, body),
    );
    const api = toApiResponse(result, { correlation_id: correlationId });
    logEvent({ correlation_id: correlationId, event: opts.eventType, ok: result.ok, reason: result.reason });
    return jsonResponse(api.status, api.body);
  } catch (e) {
    if (e instanceof InFlightError) {
      return jsonResponse(409, { ok: false, reason: "in_flight", correlation_id: correlationId });
    }
    // Erros com status explícito (ex.: ProviderNotConfiguredError → 501, ADR-019 D5).
    if (e && typeof e === "object" && "reason" in e && "status" in e &&
        typeof (e as { status: unknown }).status === "number") {
      const ne = e as { reason: string; status: number };
      logEvent({ correlation_id: correlationId, event: opts.eventType, error: ne.reason, status: ne.status });
      return jsonResponse(ne.status, { ok: false, reason: ne.reason, correlation_id: correlationId });
    }
    const msg = e instanceof Error ? e.message : String(e);
    const pgcode = (e as { pgcode?: string }).pgcode;
    logEvent({ correlation_id: correlationId, event: opts.eventType, error: msg, pgcode });
    return jsonResponse(500, { ok: false, reason: "internal_error", correlation_id: correlationId });
  }
}