import "server-only";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { RpcResult } from "@/lib/rpc/result";

/**
 * Idempotency ledger (ADR-019 D4 / R17). Escreve em `integration_events`
 * (service-only — grant só a service_role, 0015) via system-client.
 *
 * Semântica (R17 — não misturar, ADR-018 D6):
 *  - `idempotencyKey` (header `Idempotency-Key`) → **dedup de retry** (mesma call
 *    re-executada pelo n8n/Backoff).
 *  - `externalEventId` → **dedup de webhook/event inbound reprocessado**.
 *  - `external_reference` → dedup de **criação**, já tratado dentro de
 *    `create_delivery_request` (on conflict 0021:140). O ledger registra mas o
 *    guard real é a RPC.
 *  - `correlationId` → só propagação/log (NÃO é dedup).
 *
 * Os RPCs system têm guards de state-machine (`wrong_state`, `round_already_open`) e
 * `create_delivery_request` tem dedup por `external_reference`. O ledger adiciona
 * replay explícito do resultado original + auditoria. Quando **nenhuma** chave de
 * dedup está presente, a call prossegue direto (os guards da RPC protegem).
 */

export type IdempotencyOpts = {
  source: string; // ex.: "n8n", "internal-api", "datacrazy"
  idempotencyKey?: string | null;
  externalEventId?: string | null;
  eventType?: string | null;
  payload?: Record<string, unknown> | null;
};

export type ClaimResult =
  | { kind: "run"; tokenId: string }
  | { kind: "replay"; result: RpcResult }
  | { kind: "in_flight" }
  | { kind: "skip" }; // sem chave de dedup → prossegue sem ledger

/** Determina a chave de dedup primária (idempotency_key tem precedência). */
function dedupKey(opts: IdempotencyOpts): { column: "idempotency_key" | "external_event_id"; value: string } | null {
  if (opts.idempotencyKey) return { column: "idempotency_key", value: opts.idempotencyKey };
  if (opts.externalEventId) return { column: "external_event_id", value: opts.externalEventId };
  return null;
}

/**
 * Tenta "claimar" a idempotência antes de executar a operação mutante.
 * Retorna:
 *  - `run` → pode executar; chame `recordResult(tokenId, result)` ao fim.
 *  - `replay` → já executado antes; retorne `result` cacheado (não re-executa).
 *  - `in_flight` → outra call com a mesma chave está em andamento (race) → 409.
 *  - `skip` → sem chave de dedup; execute sem ledger.
 */
export async function claimIdempotency(
  client: SupabaseClient,
  opts: IdempotencyOpts,
): Promise<ClaimResult> {
  const key = dedupKey(opts);
  if (!key) return { kind: "skip" };

  // 1. Já existe com resultado? → replay.
  const existing = await client
    .from("integration_events")
    .select("id,result,status")
    .eq("source", opts.source)
    .eq(key.column, key.value)
    .maybeSingle();

  const row = existing.data;
  if (row) {
    if (row.result != null) {
      return { kind: "replay", result: row.result as RpcResult };
    }
    // pending: outra call em andamento.
    return { kind: "in_flight" };
  }

  // 2. Tenta inserir (claim). upsert ignore-duplicates resolve race concorrente.
  // onConflict acompanha a coluna de dedup em uso (ambas têm unique (source, <col>)).
  const insertRow = {
    source: opts.source,
    idempotency_key: opts.idempotencyKey ?? null,
    external_event_id: opts.externalEventId ?? null,
    event_type: opts.eventType ?? null,
    payload: opts.payload ?? null,
    status: "pending",
  };
  const ins = await client
    .from("integration_events")
    .upsert(insertRow, { onConflict: `source,${key.column}`, ignoreDuplicates: true })
    .select("id")
    .maybeSingle();

  if (ins.data) {
    return { kind: "run", tokenId: ins.data.id as string };
  }

  // 3. Conflito (race): outra call inseriu entre nosso select e insert. Re-avalia.
  const recheck = await client
    .from("integration_events")
    .select("id,result,status")
    .eq("source", opts.source)
    .eq(key.column, key.value)
    .maybeSingle();

  if (recheck.data) {
    if (recheck.data.result != null) return { kind: "replay", result: recheck.data.result as RpcResult };
    return { kind: "in_flight" };
  }
  // Não deveria acontecer — fallback seguro: executar.
  return { kind: "skip" };
}

/** Registra o resultado da operação no token claimado. */
export async function recordResult(
  client: SupabaseClient,
  tokenId: string,
  result: RpcResult,
): Promise<void> {
  await client
    .from("integration_events")
    .update({ result: result as unknown as Record<string, unknown>, status: "processed", processed_at: new Date().toISOString() })
    .eq("id", tokenId);
}

/**
 * Wrapper: claim → executar fn → registrar. `fn` só roda se `run` ou `skip`.
 * Retorna o resultado (executado ou replayed). Lança `InFlightError` se in_flight.
 */
export class InFlightError extends Error {
  reason = "in_flight";
  status = 409;
}

export async function withIdempotency(
  client: SupabaseClient,
  opts: IdempotencyOpts,
  fn: () => Promise<RpcResult>,
): Promise<RpcResult> {
  const claim = await claimIdempotency(client, opts);
  if (claim.kind === "replay") return claim.result;
  if (claim.kind === "in_flight") throw new InFlightError();
  if (claim.kind === "skip") return fn();
  const result = await fn();
  await recordResult(client, claim.tokenId, result);
  return result;
}