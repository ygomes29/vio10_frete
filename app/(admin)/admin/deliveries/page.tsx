import { redirect } from "next/navigation";
import { getAdminContext } from "@/lib/server/admin-context";
import { listDeliveries } from "@/lib/services/admin-reads";
import { DeliveriesTable, Pagination, type DeliveryRow } from "@/components/admin/deliveries-table";
import { StatusFilter } from "@/components/admin/status-filter";
import { Suspense } from "react";

export const dynamic = "force-dynamic";

/**
 * `/admin/deliveries` — lista paginada de corridas com filtro de status (Sessão 18
 * / ADR-024 D7). Server Component lê `searchParams` (Promise no Next 16) e chama
 * `listDeliveries` (user-scoped, RLS). Filtro/paginação server-driven via URL.
 */
export default async function DeliveriesPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const ctx = await getAdminContext();
  if (!ctx) redirect("/auth/login?redirect=/admin/deliveries");

  const sp = await searchParams;
  const status = typeof sp.status === "string" ? sp.status : null;
  const businessId = typeof sp.business_id === "string" ? sp.business_id : null;
  const limit = Number(typeof sp.limit === "string" ? sp.limit : "25") || 25;
  const offset = Number(typeof sp.offset === "string" ? sp.offset : "0") || 0;

  const result = await listDeliveries(ctx.client, { status, businessId, limit, offset });
  if (!result.ok) {
    return (
      <div className="rounded-md border border-destructive/40 bg-destructive/5 p-4 text-sm text-destructive">
        Falha ao carregar corridas: {result.reason}
      </div>
    );
  }

  const rows = (result.deliveries ?? []) as DeliveryRow[];
  const hasMore = Boolean(result.has_more);
  const basePath = "/admin/deliveries";
  const qs = new URLSearchParams();
  if (status) qs.set("status", status);
  if (businessId) qs.set("business_id", businessId);
  const filterQs = qs.toString();

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between gap-4">
        <h1 className="text-xl font-bold">Corridas</h1>
        <Suspense fallback={null}>
          <StatusFilter current={status} />
        </Suspense>
      </div>
      <DeliveriesTable rows={rows} />
      <Pagination
        offset={offset}
        limit={limit}
        hasMore={hasMore}
        basePath={filterQs ? `${basePath}?${filterQs}` : basePath}
      />
    </div>
  );
}