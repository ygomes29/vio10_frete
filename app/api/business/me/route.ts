import { handleBusinessGet } from "@/lib/api/business-handler";
import { getBusinessMe } from "@/lib/services/business-reads";

/**
 * `GET /api/business/me` (business-scoped, cookie JWT — Sessão 19 / ADR-025 D1).
 * Contexto do business user: memberships (RPC DEFINER `my_org_memberships`) +
 * organizations/businesses/business_locations (RLS escopa ao tenant via `my_org_ids()`).
 * Leitura user-scoped. **Sem `service_role`**. Defense-in-depth: 403 se sem membership
 * (no handler). Read-only.
 */
export async function GET(request: Request): Promise<Response> {
  return handleBusinessGet(request, {
    eventType: "business.me",
    run: async (_corr, _url, ctx) => getBusinessMe(ctx.client),
  });
}