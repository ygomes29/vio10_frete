import "server-only";
import { jsonResponse, getCorrelationId, logEvent } from "./http";
import { createServerClient } from "@/lib/supabase/server-client";
import { toApiResponse } from "@/lib/rpc/result";
import type { RpcResult } from "@/lib/rpc/result";
import { resolveOrgMemberships, type OrgMembership } from "@/lib/auth/landing";
import type { SupabaseClient, User } from "@supabase/supabase-js";

type BusinessCtx = { user: User; client: SupabaseClient; memberships: OrgMembership[] };

type BusinessGetOpts = {
  eventType: string;
  run: (correlationId: string, url: URL, ctx: BusinessCtx) => Promise<RpcResult>;
};

/**
 * Fluxo dos Route Handlers **business** (Sessão 19 / ADR-025 D1/D4): cookie JWT →
 * getUser → `resolveOrgMemberships` (defense-in-depth: **403 `not_authorized`** se o
 * caller não tem ≥1 membership de organization — o middleware só checa sessão, não
 * membership; sem isto um driver autenticado receberia vazio em `/api/business/*`) →
 * `run` (client **user-scoped**, RLS `can_view_delivery_request`/`my_org_ids()` escopa ao
 * tenant) → `toApiResponse`. **Sem `service_role`** (leitura via RLS), sem idempotency
 * ledger (read-only). `url` repassado p/ `searchParams` (ex.: `?status=&limit=&offset=`).
 *
 * Espelho de `handleAdminGet` (Sessão 18), mas set-returning (membership N:1) em vez de
 * role 1:1. Regra mestra: o portal só apresenta estado oficial; nenhuma mutação aqui.
 */
export async function handleBusinessGet(request: Request, opts: BusinessGetOpts): Promise<Response> {
  const correlationId = getCorrelationId(request);

  const client = await createServerClient();
  const { data: { user } } = await client.auth.getUser();
  if (!user) {
    logEvent({ correlation_id: correlationId, event: opts.eventType, error: "unauthenticated" });
    return jsonResponse(401, { ok: false, reason: "unauthenticated", correlation_id: correlationId });
  }

  const memberships = await resolveOrgMemberships(client, user.id);
  if (memberships.length === 0) {
    logEvent({ correlation_id: correlationId, event: opts.eventType, error: "not_authorized" });
    return jsonResponse(403, { ok: false, reason: "not_authorized", correlation_id: correlationId });
  }

  try {
    const url = new URL(request.url);
    const result = await opts.run(correlationId, url, { user, client, memberships });
    const api = toApiResponse(result, { correlation_id: correlationId });
    logEvent({ correlation_id: correlationId, event: opts.eventType, ok: result.ok, reason: result.reason });
    return jsonResponse(api.status, api.body);
  } catch (e) {
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