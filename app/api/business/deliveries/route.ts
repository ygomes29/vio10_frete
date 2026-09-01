import { handleBusinessGet } from "@/lib/api/business-handler";
import { listDeliveries } from "@/lib/services/business-reads";

/**
 * `GET /api/business/deliveries` (business-scoped — Sessão 19 / ADR-025 D1). Lista
 * paginada das corridas do tenant com filtro de status. searchParams: `status`,
 * `limit` (default 25, max 100), `offset` (default 0). Leitura user-scoped (RLS escopa
 * ao tenant — **sem** `business_id` explícito, diferentemente do admin). Read-only.
 */
export async function GET(request: Request): Promise<Response> {
  return handleBusinessGet(request, {
    eventType: "business.deliveries.list",
    run: async (_corr, url, ctx) => {
      const sp = url.searchParams;
      const status = sp.get("status");
      const limit = Number(sp.get("limit") ?? "25") || 25;
      const offset = Number(sp.get("offset") ?? "0") || 0;
      // businessId null: RLS `delreq_sel` já escopa por `my_org_ids()`.
      return listDeliveries(ctx.client, { status, businessId: null, limit, offset });
    },
  });
}