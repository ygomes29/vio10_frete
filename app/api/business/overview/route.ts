import { handleBusinessGet } from "@/lib/api/business-handler";
import { getBusinessOverview } from "@/lib/services/business-reads";

/**
 * `GET /api/business/overview` (business-scoped, cookie JWT — Sessão 19 / ADR-025 D1/D8).
 * KPIs do tenant: corridas por estado (ativas/terminais), entregues hoje + volume em
 * centavos, falhas recentes. **Sem** KPI de entregadores (platform-wide/admin). Leitura
 * user-scoped (RLS `can_view_delivery_request`/`my_org_ids()` escopa ao tenant).
 * **Sem `service_role`**. Read-only.
 */
export async function GET(request: Request): Promise<Response> {
  return handleBusinessGet(request, {
    eventType: "business.overview",
    run: async (_corr, _url, ctx) => getBusinessOverview(ctx.client),
  });
}