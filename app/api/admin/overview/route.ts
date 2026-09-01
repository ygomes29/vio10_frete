import { handleAdminGet } from "@/lib/api/admin-handler";
import { getOverview } from "@/lib/services/admin-reads";

/**
 * `GET /api/admin/overview` (admin-scoped, cookie JWT — Sessão 18 / ADR-024 D1).
 * KPIs operacionais: corridas por estado, entregadores por disponibilidade, volume
 * do dia, falhas recentes. Leitura user-scoped (RLS `is_platform_admin()`
 * cross-tenant). **Sem `service_role`**. Defense-in-depth: 403 se não for platform
 * role (no handler). Read-only.
 */
export async function GET(request: Request): Promise<Response> {
  return handleAdminGet(request, {
    eventType: "admin.overview",
    run: async (_corr, _url, ctx) => getOverview(ctx.client),
  });
}