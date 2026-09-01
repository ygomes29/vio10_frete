import { redirect } from "next/navigation";
import { getAdminContext } from "@/lib/server/admin-context";
import { getOverview } from "@/lib/services/admin-reads";
import { OverviewKpis, type OverviewData } from "@/components/admin/overview-kpis";

export const dynamic = "force-dynamic";

/**
 * `/admin` — overview operacional (Sessão 18 / ADR-024 D7). Server Component lê
 * estado oficial via `getAdminContext()` (user-scoped, RLS `is_platform_admin()`)
 * + `getOverview` e passa ao client component (polling 30s). Sem `service_role`.
 */
export default async function AdminOverviewPage() {
  const ctx = await getAdminContext();
  if (!ctx) redirect("/auth/login?redirect=/admin");

  const result = await getOverview(ctx.client);
  if (!result.ok) {
    return (
      <div className="rounded-md border border-destructive/40 bg-destructive/5 p-4 text-sm text-destructive">
        Falha ao carregar visão geral: {result.reason}
      </div>
    );
  }

  const data = result as unknown as OverviewData;
  return <OverviewKpis initial={data} />;
}