import { handleAdminGet } from "@/lib/api/admin-handler";
import { listDeliveries } from "@/lib/services/admin-reads";

/**
 * `GET /api/admin/deliveries` (admin-scoped — Sessão 18 / ADR-024 D1). Lista
 * paginada de corridas com filtros. searchParams: `status`, `business_id`,
 * `limit` (default 25, max 100), `offset` (default 0). Leitura user-scoped
 * (RLS). Read-only.
 */
export async function GET(request: Request): Promise<Response> {
  return handleAdminGet(request, {
    eventType: "admin.deliveries.list",
    run: async (_corr, url, ctx) => {
      const sp = url.searchParams;
      const status = sp.get("status");
      const businessId = sp.get("business_id");
      const limit = Number(sp.get("limit") ?? "25") || 25;
      const offset = Number(sp.get("offset") ?? "0") || 0;
      return listDeliveries(ctx.client, { status, businessId, limit, offset });
    },
  });
}