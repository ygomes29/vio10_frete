import "server-only";
import { jsonResponse, getCorrelationId, logEvent } from "./http";
import { createServerClient } from "@/lib/supabase/server-client";
import { toApiResponse } from "@/lib/rpc/result";
import type { RpcResult } from "@/lib/rpc/result";
import { resolvePlatformRole } from "@/lib/auth/landing";
import type { SupabaseClient, User } from "@supabase/supabase-js";

type AdminCtx = { user: User; client: SupabaseClient; role: string };

type AdminGetOpts = {
  eventType: string;
  run: (correlationId: string, url: URL, ctx: AdminCtx) => Promise<RpcResult>;
};

/**
 * Fluxo dos Route Handlers **admin** (Sessão 18 / ADR-024 D1/D5): cookie JWT →
 * getUser → `resolvePlatformRole` (defense-in-depth: **403 `not_authorized`** se o
 * caller não for super_admin/admin/operator — o middleware só checa sessão, não
 * role; sem isto um driver autenticado receberia vazio em `/api/admin/*`) → `run`
 * (client **user-scoped**, RLS `is_platform_admin()` aplica cross-tenant) →
 * `toApiResponse`. **Sem `service_role`** (leitura via RLS), sem idempotency ledger
 * (read-only). `url` repassado p/ `searchParams` (ex.: `?status=&limit=&offset=`).
 *
 * Regra mestra: o dashboard só apresenta estado oficial; nenhuma mutação aqui.
 */
export async function handleAdminGet(request: Request, opts: AdminGetOpts): Promise<Response> {
  const correlationId = getCorrelationId(request);

  const client = await createServerClient();
  const { data: { user } } = await client.auth.getUser();
  if (!user) {
    logEvent({ correlation_id: correlationId, event: opts.eventType, error: "unauthenticated" });
    return jsonResponse(401, { ok: false, reason: "unauthenticated", correlation_id: correlationId });
  }

  const role = await resolvePlatformRole(client, user.id);
  if (!role) {
    logEvent({ correlation_id: correlationId, event: opts.eventType, error: "not_authorized" });
    return jsonResponse(403, { ok: false, reason: "not_authorized", correlation_id: correlationId });
  }

  try {
    const url = new URL(request.url);
    const result = await opts.run(correlationId, url, { user, client, role });
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