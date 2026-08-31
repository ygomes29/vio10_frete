import "server-only";
import { jsonResponse, getCorrelationId, getIdempotencyHeaders, logEvent } from "./http";
import { createServerClient } from "@/lib/supabase/server-client";
import { toApiResponse, reasonToStatus } from "@/lib/rpc/result";
import type { RpcResult } from "@/lib/rpc/result";
import type { SupabaseClient, User } from "@supabase/supabase-js";

type UserCtx = { user: User; client: SupabaseClient };

type UserHandlerOpts = {
  eventType: string;
  /** Validação pré-RPC (falha não vira replay — não há ledger em user-facing, D7). */
  validate?: (body: unknown) => string | null;
  /** Executa a operação. Recebe correlation_id, body e o contexto {user, client user-scoped}. */
  run: (correlationId: string, body: unknown, ctx: UserCtx) => Promise<RpcResult>;
  /** Se true, não loga o body/resultado detalhado (ex.: POD c/ otp_code — ADR-020 D9). */
  sensitive?: boolean;
};

/**
 * Fluxo dos Route Handlers **user/driver-facing** (ADR-020 D1): cookie JWT.
 *   getUser → 401 se null → parse → validate → RPC (user-scoped, RLS aplica) → map → HTTP.
 * Sem idempotency ledger (D7): RPCs user-facing usam guards internos (idempotency_key
 * interna de respond_to_offer, unique POD, máquina de estados). `service_role` não é
 * usado aqui — o client é user-scoped (cookie → auth.uid()).
 */
export async function handleUserPost(request: Request, opts: UserHandlerOpts): Promise<Response> {
  const correlationId = getCorrelationId(request);

  const client = await createServerClient();
  const { data: { user } } = await client.auth.getUser();
  if (!user) {
    logEvent({ correlation_id: correlationId, event: opts.eventType, error: "unauthenticated" });
    return jsonResponse(401, { ok: false, reason: "unauthenticated", correlation_id: correlationId });
  }

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

  try {
    const result = await opts.run(correlationId, body, { user, client });
    const api = toApiResponse(result, { correlation_id: correlationId });
    logEvent(
      opts.sensitive
        ? { correlation_id: correlationId, event: opts.eventType, ok: result.ok, reason: result.reason }
        : { correlation_id: correlationId, event: opts.eventType, ok: result.ok, reason: result.reason },
    );
    return jsonResponse(api.status, api.body);
  } catch (e) {
    // Erros com status explícito (ex.: ProviderNotConfiguredError).
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

/** Exporta o idempotency header p/ handlers que repassam à RPC (respond_to_offer). */
export function idempotencyKeyOf(request: Request): string | null {
  return getIdempotencyHeaders(request).idempotencyKey;
}