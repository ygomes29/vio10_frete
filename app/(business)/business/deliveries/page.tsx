import { redirect } from "next/navigation";
import { getBusinessContext } from "@/lib/server/business-context";
import { listDeliveries } from "@/lib/services/business-reads";
import { DeliveriesTable, Pagination, type DeliveryRow } from "@/components/admin/deliveries-table";
import { StatusFilter } from "@/components/admin/status-filter";
import { Suspense } from "react";

export const dynamic = "force-dynamic";

/**
 * `/business/deliveries` — lista paginada das corridas do tenant com filtro de status
 * (Sessão 19 / ADR-025 D7). Server Component lê `searchParams` (Promise no Next 16) e
 * chama `listDeliveries` sem `businessId` (RLS `delreq_sel`→`my_org_ids()` escopa ao
 * tenant). Filtro/paginação server-driven via URL.
 */
export default async function BusinessDeliveriesPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const ctx = await getBusinessContext();
  if (!ctx) redirect("/auth/login?redirect=/business/deliveries");

  const sp = await searchParams;
  const status = typeof sp.status === "string" ? sp.status : null;
  const limit = Number(typeof sp.limit === "string" ? sp.limit : "25") || 25;
  const offset = Number(typeof sp.offset === "string" ? sp.offset : "0") || 0;

  const result = await listDeliveries(ctx.client, { status, businessId: null, limit, offset });
  if (!result.ok) {
    return (
      <div className="rounded-md border border-destructive/40 bg-destructive/5 p-4 text-sm text-destructive">
        Falha ao carregar corridas: {result.reason}
      </div>
    );
  }

  const rows = (result.deliveries ?? []) as DeliveryRow[];
  const hasMore = Boolean(result.has_more);
  const basePath = "/business/deliveries";
  const qs = new URLSearchParams();
  if (status) qs.set("status", status);
  const filterQs = qs.toString();

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between gap-4">
        <h1 className="text-xl font-bold">Corridas</h1>
        <Suspense fallback={null}>
          <StatusFilter current={status} basePath="/business/deliveries" />
        </Suspense>
      </div>
      <DeliveriesTable
        rows={rows}
        detailHref={(id) => `/business/deliveries/${id}`}
      />
      <Pagination
        offset={offset}
        limit={limit}
        hasMore={hasMore}
        basePath={filterQs ? `${basePath}?${filterQs}` : basePath}
      />
    </div>
  );
}