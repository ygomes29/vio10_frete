/**
 * Mapeamento resultado RPC → HTTP (ADR-019 D6). Os RPCs retornam
 * `table(ok boolean, reason text, ...)` (SECURITY DEFINER). A camada de API traduz
 * `(ok, reason)` em status + corpo, sem vazar stack traces.
 */

export type RpcResult = {
  ok: boolean;
  reason: string | null;
  [key: string]: unknown;
};

/** reason → HTTP status. Conflitos de estado/identidade = 409; pré-condições = 422. */
export function reasonToStatus(reason: string | null): number {
  if (!reason) return 500;
  switch (reason) {
    // autenticação (camada de API: sem/inválido JWT antes da RPC)
    case "unauthenticated":
      return 401;
    // autorização
    case "not_authorized":
      return 403;
    // input inválido
    case "invalid_param":
    case "invalid_bid_amount":
    case "invalid_response_type":
    case "invalid_pod":
      return 400;
    // conflito de estado / idempotência de estado (replay já-sucesso é 200, ver abaixo)
    case "wrong_state":
    case "round_already_open":
    case "round_not_open":
    case "already_responded":
    case "offer_already_responded":
    case "delivery_not_searching":
    case "pod_already_submitted":
    case "invalid_transition":
    case "reassignment_limit_reached":
    case "otp_already_used":
      return 409;
    // recurso gone (oferta vencida — já não existe p/ efeito prático)
    case "offer_expired":
      return 410;
    // não-encontrado (escopo: offer não pertence ao driver)
    case "offer_not_found_for_driver":
      return 404;
    // pré-condição negada (recurso/estado esperado não satisfeito)
    case "not_found":
    case "delivery_not_found":
    case "no_pricing_rule":
    case "pod_required":
    case "pickup_pod_required":
    case "pod_geolocation_out_of_range":
    case "otp_not_generated":
    case "otp_expired":
    case "otp_max_attempts":
    case "otp_invalid":
      return 422;
    default:
      return 422; // reason desconhecido do backend → 422 (não 500: o backend respondeu)
  }
}

/** Replay idempotente = sucesso cacheado → 200, não 409. */
export function isReplay(reason: string | null): boolean {
  return reason === "idempotent_replay";
}

export type ApiResponse = {
  status: number;
  body: Record<string, unknown>;
};

/** Constrói a Response JSON a partir de um RpcResult. */
export function toApiResponse(result: RpcResult, extra?: Record<string, unknown>): ApiResponse {
  if (result.ok || isReplay(result.reason)) {
    return { status: 200, body: { ...result, ...extra, ok: true } };
  }
  const status = reasonToStatus(result.reason);
  return {
    status,
    body: { ok: false, reason: result.reason, ...extra },
  };
}

/**
 * Redact (remove) chaves do corpo da resposta. Usado para segurar invariantes de
 * secrets: ex.: `otp_code` jamais sai do backend (ADR-021 D7). Aplica-se em first-call
 * E replay (replay devolve o `RpcResult` cacheado, que conteria o campo). Não lança.
 */
export function redactFields(body: Record<string, unknown>, keys: string[]): Record<string, unknown> {
  if (!keys.length) return body;
  const out = { ...body };
  for (const k of keys) delete out[k];
  return out;
}