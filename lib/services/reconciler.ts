import "server-only";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { RpcResult } from "@/lib/rpc/result";

/**
 * Reconciler scan (ADR-021, read-only). `POST /api/internal/reconciler/scan` — o n8n
 * (Schedule Trigger) chama periodicamente; o backend faz as queries (service_role) e
 * retorna os achados stale. n8n **não** query o DB direto (regra mestra) — só chama
 * Route Handlers p/ reprocessar cada achado.
 *
 * **Read-only**: sem mutação. O caller NÃO envia `Idempotency-Key` (ledger `skip` →
 * re-query sempre; cache seria stale p/ um scan).
 *
 * Achados:
 *  (a) `stale_rounds`     — dispatch_rounds status='open' AND expires_at < now() (timeout perdido).
 *  (b) `stale_drafts`     — delivery_requests status='draft' há mais de `stale_after_seconds` (enrich/quote não rodou).
 *  (c) `orphaned_searching` — delivery_requests status='searching_driver' sem rodada aberta (dispatch perdido).
 */

export type ReconcilerFindings = {
  stale_rounds: Array<{ id: string; delivery_request_id: string; round_number: number; expires_at: string }>;
  stale_drafts: Array<{ id: string; created_at: string }>;
  orphaned_searching: Array<{ id: string; dispatch_started_at: string | null }>;
};

export type ScanInput = {
  stale_after_seconds?: number;
};

export function validateScanBody(body: unknown): { valid: true } | { valid: false; reason: string } {
  if (body === null || body === undefined) return { valid: true }; // body vazio ok (defaults)
  if (typeof body !== "object") return { valid: false, reason: "invalid_param" };
  const b = body as Record<string, unknown>;
  if (b.stale_after_seconds !== undefined && b.stale_after_seconds !== null) {
    if (typeof b.stale_after_seconds !== "number" || !Number.isFinite(b.stale_after_seconds) || b.stale_after_seconds <= 0) {
      return { valid: false, reason: "invalid_param" };
    }
  }
  return { valid: true };
}

export async function scanReconciler(
  client: SupabaseClient,
  input: ScanInput,
): Promise<RpcResult & ReconcilerFindings> {
  const staleAfterSeconds = input.stale_after_seconds ?? 300;

  // (a) rounds abertos expirados.
  const { data: rounds } = await client
    .from("dispatch_rounds")
    .select("id, delivery_request_id, round_number, expires_at")
    .eq("status", "open")
    .lt("expires_at", new Date().toISOString());

  // (b) drafts sem quote há mais de stale_after_seconds.
  const cutoff = new Date(Date.now() - staleAfterSeconds * 1000).toISOString();
  const { data: drafts } = await client
    .from("delivery_requests")
    .select("id, created_at")
    .eq("status", "draft")
    .lt("created_at", cutoff);

  // (c) searching_driver sem rodada aberta — query via not exists (RPC-free, service_role bypassa RLS).
  // Busca searching_driver e filtra os que têm rodada open via pós-filtro (conjunto pequeno no MVP).
  const { data: searching } = await client
    .from("delivery_requests")
    .select("id, dispatch_started_at")
    .eq("status", "searching_driver");
  const orphaned: Array<{ id: string; dispatch_started_at: string | null }> = [];
  if (searching && searching.length > 0) {
    const ids = searching.map((r) => (r as { id: string }).id);
    const { data: openRounds } = await client
      .from("dispatch_rounds")
      .select("delivery_request_id")
      .eq("status", "open")
      .in("delivery_request_id", ids);
    const withOpen = new Set((openRounds ?? []).map((r) => (r as { delivery_request_id: string }).delivery_request_id));
    for (const r of searching) {
      const row = r as { id: string; dispatch_started_at: string | null };
      if (!withOpen.has(row.id)) orphaned.push({ id: row.id, dispatch_started_at: row.dispatch_started_at });
    }
  }

  const findings: ReconcilerFindings = {
    stale_rounds: (rounds ?? []) as ReconcilerFindings["stale_rounds"],
    stale_drafts: (drafts ?? []) as ReconcilerFindings["stale_drafts"],
    orphaned_searching: orphaned,
  };
  return { ok: true, reason: null, ...findings };
}