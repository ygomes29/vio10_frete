import "server-only";
import { jsonResponse, getCorrelationId, getIdempotencyHeaders, logEvent } from "./http";
import { createServerClient } from "@/lib/supabase/server-client";
import { createSystemClient } from "@/lib/supabase/system-client";
import { verifyActionLink } from "@/lib/auth/signed-link";
import { toApiResponse, reasonToStatus } from "@/lib/rpc/result";
import type { RpcResult } from "@/lib/rpc/result";

type OfferRespondOpts = {
  /** Valida o body normalizado {driver_id, response_type, bid_amount_cents?}. Retorna reason ou null. */
  validate: (body: unknown) => string | null;
  /** Executa respond_to_offer com o client + input apropriados ao modo de auth. */
  runSystem: (correlationId: string, input: { offerId: string; driverId: string; responseType: string; bidAmountCents: number | null; idempotencyKey: string | null }) => Promise<RpcResult>;
  runUser: (correlationId: string, input: { offerId: string; driverId: string; responseType: string; bidAmountCents: number | null; idempotencyKey: string | null }) => Promise<RpcResult>;
};

/**
 * `POST /api/offers/{id}/respond` — dual auth (ADR-020 D1).
 *   1. Tenta cookie JWT (PWA logado): getUser → user-scoped, driver_id do body.
 *   2. Sem cookie → signed link HMAC (`?token=` ou header `x-offer-token`): system-scoped,
 *      driver_id do token, offer_id deve casar c/ o path (IDOR). O binding (offer,driver)+exp
 *      **é** a autorização.
 *   3. Nem cookie nem token válido → 401.
 * Idempotência **interna** da RPC (não usa ledger, D7). ACEITAR ≠ GANHAR (não atribui).
 */
export async function handleOfferRespondPost(
  request: Request,
  offerId: string,
  opts: OfferRespondOpts,
): Promise<Response> {
  const correlationId = getCorrelationId(request);
  const idempotencyKey = getIdempotencyHeaders(request).idempotencyKey;

  let body: unknown = null;
  try {
    const text = await request.text();
    if (text.trim() !== "") body = JSON.parse(text);
  } catch {
    return jsonResponse(400, { ok: false, reason: "invalid_param", detail: "body json inválido", correlation_id: correlationId });
  }

  // ---- Modo 1: cookie JWT (PWA logado) ----
  const userClient = await createServerClient();
  const { data: { user } } = await userClient.auth.getUser();
  if (user) {
    const reason = opts.validate(body);
    if (reason) {
      return jsonResponse(reasonToStatus(reason), { ok: false, reason, correlation_id: correlationId });
    }
    const b = body as { driver_id: string; response_type: string; bid_amount_cents?: number | null };
    try {
      const result = await opts.runUser(correlationId, {
        offerId,
        driverId: b.driver_id,
        responseType: b.response_type,
        bidAmountCents: b.bid_amount_cents ?? null,
        idempotencyKey,
      });
      const api = toApiResponse(result, { correlation_id: correlationId });
      logEvent({ correlation_id: correlationId, event: "offer.respond", mode: "cookie", ok: result.ok, reason: result.reason });
      return jsonResponse(api.status, api.body);
    } catch (e) {
      return handleErr(e as ErrorLike, correlationId, "offer.respond");
    }
  }

  // ---- Modo 2: signed link HMAC (WhatsApp, sem login) ----
  const url = new URL(request.url);
  const token = url.searchParams.get("token") ?? request.headers.get("x-offer-token");
  const verified = token ? verifyActionLink(token, offerId) : null;
  if (!verified) {
    logEvent({ correlation_id: correlationId, event: "offer.respond", error: "unauthenticated", mode: "token" });
    return jsonResponse(401, { ok: false, reason: "unauthenticated", correlation_id: correlationId });
  }

  // driver_id vem do token; injeta no body antes de validar (o validator exige driver_id).
  const merged = { ...(body as Record<string, unknown> | null) ?? {}, driver_id: verified.driverId };
  const reason = opts.validate(merged);
  if (reason) {
    return jsonResponse(reasonToStatus(reason), { ok: false, reason, correlation_id: correlationId });
  }
  const b = merged as { driver_id: string; response_type: string; bid_amount_cents?: number | null };
  try {
    const result = await opts.runSystem(correlationId, {
      offerId,
      driverId: verified.driverId,
      responseType: b.response_type,
      bidAmountCents: b.bid_amount_cents ?? null,
      idempotencyKey,
    });
    const api = toApiResponse(result, { correlation_id: correlationId });
    logEvent({ correlation_id: correlationId, event: "offer.respond", mode: "token", ok: result.ok, reason: result.reason });
    return jsonResponse(api.status, api.body);
  } catch (e) {
    return handleErr(e as ErrorLike, correlationId, "offer.respond");
  }
}

type ErrorLike = { message?: string; reason?: string; status?: unknown; pgcode?: string };

function handleErr(e: ErrorLike, correlationId: string, event: string): Response {
  if (e && typeof e.status === "number" && typeof e.reason === "string") {
    logEvent({ correlation_id: correlationId, event, error: e.reason, status: e.status });
    return jsonResponse(e.status, { ok: false, reason: e.reason, correlation_id: correlationId });
  }
  logEvent({ correlation_id: correlationId, event, error: e?.message ?? String(e), pgcode: e?.pgcode });
  return jsonResponse(500, { ok: false, reason: "internal_error", correlation_id: correlationId });
}