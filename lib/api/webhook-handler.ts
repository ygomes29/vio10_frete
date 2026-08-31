import "server-only";
import { jsonResponse, getCorrelationId, logEvent } from "./http";
import { verifyDatacrazySignature, getDatacrazySignature } from "./webhook-auth";
import { createSystemClient } from "@/lib/supabase/system-client";
import type { SupabaseClient } from "@supabase/supabase-js";

// `createSystemClient()` retorna `ReturnType<typeof createClient>`; anotar como
// `SupabaseClient` (default Database=any) mantém o `.from()` permissivo, igual ao
// `client: SupabaseClient` do ledger.ts — evita inferência `never` em tabelas
// fora de um schema tipado (sem `Database` generado no MVP).

type WebhookHandlerOpts = {
  source: string; // ex.: "datacrazy"
  /** external_id do emissor (header obrigatório p/ dedup). Retorna o valor ou null. */
  externalId: (request: Request) => string | null;
  /** Roteia o intent (parse + dispatcha p/ service). Erros logados; sempre 200 ao caller. */
  route: (client: SupabaseClient, payload: Record<string, unknown>, correlationId: string) => Promise<void>;
  /**
   * Captura best-effort de contexto de conversa (ex.: upsert whatsapp_conversations do
   * inbound DataCrazy — ADR-021 D1). Roda após dedup, ANTES do roteamento. Erros são
   * logados e NÃO derrubam o roteamento (enriquecimento, não crítico).
   */
  captureConversation?: (client: SupabaseClient, payload: Record<string, unknown>, correlationId: string) => Promise<void>;
};

/**
 * Fluxo dos webhooks inbound (ADR-020 D5): signature → dedup via `webhook_events` →
 * parse/roteamento → 200. Público (sem JWT), protegido por signature. Dedup por
 * `(source, external_id)` (R17 inbound). DataCrazy nunca escreve no banco — chama services.
 */
export async function handleWebhookPost(request: Request, opts: WebhookHandlerOpts): Promise<Response> {
  const correlationId = getCorrelationId(request);
  const raw = await request.text();

  // 1. signature (fail-closed).
  if (!verifyDatacrazySignature(raw, getDatacrazySignature(request))) {
    logEvent({ correlation_id: correlationId, event: `${opts.source}.webhook`, error: "invalid_signature" });
    return jsonResponse(401, { ok: false, reason: "invalid_signature", correlation_id: correlationId });
  }

  // 2. external_id obrigatório (dedup key).
  const externalId = opts.externalId(request);
  if (!externalId) {
    return jsonResponse(400, { ok: false, reason: "invalid_param", detail: "external_id ausente", correlation_id: correlationId });
  }

  // 3. parse body (já validada signature; payload estruturado pela IA).
  let payload: Record<string, unknown> = {};
  try {
    payload = raw.trim() === "" ? {} : JSON.parse(raw);
  } catch {
    return jsonResponse(400, { ok: false, reason: "invalid_param", detail: "body json inválido", correlation_id: correlationId });
  }

  const client: SupabaseClient = createSystemClient();

  // 4. dedup via webhook_events (source, external_id) UNIQUE. Insere pending; se já existe
  //    → duplicado → 200 no-op (idempotent_replay). upsert c/ ignoreDuplicates: true.
  const { data: inserted } = await client
    .from("webhook_events")
    .upsert(
      { source: opts.source, external_id: externalId, event_type: (payload as { intent?: string }).intent ?? null, payload, signature_valid: true, status: "pending" },
      { onConflict: "source,external_id", ignoreDuplicates: true },
    )
    .select("id")
    .maybeSingle();

  if (!inserted) {
    // já processado antes — replay.
    logEvent({ correlation_id: correlationId, event: `${opts.source}.webhook`, ok: true, reason: "idempotent_replay" });
    return jsonResponse(200, { ok: true, reason: "idempotent_replay", correlation_id: correlationId });
  }

  // 5. roteamento (parse + dispatch). Erros não derrubam o 200 ao emissor (webhook não pode
  //    depender de processamento caro); loga + marca status. Reconciler backstop (ADR-018 D7).
  //    Antes: captura best-effort de conversa (enriquecimento p/ roteamento outbound híbrido).
  if (opts.captureConversation) {
    try {
      await opts.captureConversation(client, payload, correlationId);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      logEvent({ correlation_id: correlationId, event: `${opts.source}.webhook`, error: `capture_failed: ${msg}` });
      // não aborta — o roteamento do intent é a prioridade.
    }
  }
  try {
    await opts.route(client, payload, correlationId);
    await client.from("webhook_events").update({ status: "processed", processed_at: new Date().toISOString() }).eq("id", (inserted as { id: string }).id);
    logEvent({ correlation_id: correlationId, event: `${opts.source}.webhook`, ok: true });
    return jsonResponse(200, { ok: true, correlation_id: correlationId });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    const pgcode = (e as { pgcode?: string }).pgcode;
    await client.from("webhook_events").update({ status: "failed" }).eq("id", (inserted as { id: string }).id).then(() => undefined, () => undefined);
    logEvent({ correlation_id: correlationId, event: `${opts.source}.webhook`, error: msg, pgcode });
    // 200 p/ o emissor (não reenviar); o reconciler/DLQ trata. Payload desconhecido = 200 + DLQ.
    return jsonResponse(200, { ok: true, reason: "routed_with_error", correlation_id: correlationId });
  }
}