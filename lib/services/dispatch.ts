import "server-only";
import { createSystemClient } from "@/lib/supabase/system-client";
import { callRpc } from "@/lib/rpc/call";
import type { RpcResult } from "@/lib/rpc/result";

export type OpenDispatchInput = {
  delivery_request_id: string;
  search_radius_m: number;
  max_candidates: number;
  driver_offer_cents: number;
  response_window_seconds: number;
  max_location_age_seconds?: number;
};

/**
 * Valida o **body** de abertura de rodada. `delivery_request_id` **não** é esperado
 * no body — vem do path (`/deliveries/[id]/dispatch/rounds`) e é injetado pelo handler.
 */
export function validateDispatchRoundBody(body: unknown): ValidationResult {
  if (!body || typeof body !== "object") return { valid: false, reason: "invalid_param" };
  const b = body as Partial<OpenDispatchInput>;
  const required: Array<keyof OpenDispatchInput> = [
    "search_radius_m", "max_candidates", "driver_offer_cents", "response_window_seconds",
  ];
  for (const k of required) {
    if (b[k] === undefined || b[k] === null) return { valid: false, reason: "invalid_param" };
  }
  if (typeof b.search_radius_m !== "number" || b.search_radius_m <= 0 ||
      typeof b.max_candidates !== "number" || b.max_candidates <= 0 ||
      typeof b.driver_offer_cents !== "number" || b.driver_offer_cents < 0 ||
      typeof b.response_window_seconds !== "number" || b.response_window_seconds <= 0) {
    return { valid: false, reason: "invalid_param" };
  }
  if (b.max_location_age_seconds !== undefined &&
      (typeof b.max_location_age_seconds !== "number" || b.max_location_age_seconds <= 0)) {
    return { valid: false, reason: "invalid_param" };
  }
  return { valid: true };
}

/**
 * `POST /api/internal/deliveries/{id}/dispatch/rounds` → `open_dispatch_round`
 * (system-only). Abre **uma** rodada por chamada; `round_already_open` guarda
 * sobreposição. O loop de raio progressivo é do n8n (ADR-013 D5 / ADR-018 D4).
 */
export async function openDispatchRound(
  input: OpenDispatchInput,
  correlationId: string,
): Promise<RpcResult> {
  const client = createSystemClient();
  return callRpc(client, "open_dispatch_round", {
    p_delivery_request_id: input.delivery_request_id,
    p_search_radius_m: input.search_radius_m,
    p_max_candidates: input.max_candidates,
    p_driver_offer_cents: input.driver_offer_cents,
    p_response_window_seconds: input.response_window_seconds,
    p_max_location_age_seconds: input.max_location_age_seconds ?? 300,
    p_correlation_id: correlationId,
  });
}

/**
 * `POST /api/internal/dispatch/rounds/{id}/close` → `select_winner_and_claim`
 * (system-only). Pontua + chama `claim_delivery` atomicamente (GATE Sessão 10).
 * n8n **não** decide atribuição — só pede o close; o resultado (won/no_candidates/
 * superseded_by_concurrent_claim) vem do SWAC (ADR-018 D9, ACEITAR ≠ GANHAR ADR-006).
 */
export async function closeDispatchRound(
  roundId: string,
  opts: { weightPrice?: number; weightDistance?: number; maxLocationAgeSeconds?: number },
  correlationId: string,
): Promise<RpcResult> {
  const client = createSystemClient();
  return callRpc(client, "select_winner_and_claim", {
    p_dispatch_round_id: roundId,
    p_weight_price: opts.weightPrice ?? 1.0,
    p_weight_distance: opts.weightDistance ?? 1.0,
    p_max_location_age_seconds: opts.maxLocationAgeSeconds ?? 300,
    p_correlation_id: correlationId,
  });
}

type ValidationResult = { valid: true } | { valid: false, reason: string };