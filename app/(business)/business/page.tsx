import { redirect } from "next/navigation";
import { getBusinessContext } from "@/lib/server/business-context";
import { getBusinessOverview } from "@/lib/services/business-reads";
import {
  BusinessOverviewKpis,
  type BusinessOverviewData,
} from "@/components/business/overview-kpis";

export const dynamic = "force-dynamic";

/**
 * `/business` — overview do tenant (Sessão 19 / ADR-025 D7). Server Component lê estado
 * oficial via `getBusinessContext()` (user-scoped, RLS escopa ao tenant) +
 * `getBusinessOverview` e passa ao client component (polling 30s). Sem `service_role`,
 * read-only. **Sem** KPI de entregadores (D8).
 */
export default async function BusinessOverviewPage() {
  const ctx = await getBusinessContext();
  if (!ctx) redirect("/auth/login?redirect=/business");

  const result = await getBusinessOverview(ctx.client);
  if (!result.ok) {
    return (
      <div className="rounded-md border border-destructive/40 bg-destructive/5 p-4 text-sm text-destructive">
        Falha ao carregar visão geral: {result.reason}
      </div>
    );
  }

  const data = result as unknown as BusinessOverviewData;
  return <BusinessOverviewKpis initial={data} />;
}