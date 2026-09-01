import Link from "next/link";
import { redirect } from "next/navigation";
import { getAdminContext } from "@/lib/server/admin-context";
import { getDeliveryDetail } from "@/lib/services/admin-reads";
import { DeliveryDetailTabs, type DeliveryDetail } from "@/components/admin/delivery-detail-tabs";
import { ArrowLeft } from "lucide-react";

export const dynamic = "force-dynamic";

/**
 * `/admin/deliveries/{id}` — detalhe da corrida (Sessão 18 / ADR-024 D7). Server
 * Component lê estado oficial via `getAdminContext()` + `getDeliveryDetail`
 * (user-scoped, RLS `is_platform_admin()`) e passa ao client component (Tabs +
 * mapa Leaflet). Sem `service_role`, read-only.
 */
export default async function DeliveryDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const ctx = await getAdminContext();
  if (!ctx) redirect(`/auth/login?redirect=/admin/deliveries/${id}`);

  const result = await getDeliveryDetail(ctx.client, id);
  if (!result.ok) {
    return (
      <div className="space-y-4">
        <Link href="/admin/deliveries" className="inline-flex items-center gap-1 text-sm text-primary hover:underline">
          <ArrowLeft className="h-4 w-4" /> Voltar
        </Link>
        <div className="rounded-md border border-destructive/40 bg-destructive/5 p-4 text-sm text-destructive">
          {result.reason === "not_found"
            ? "Corrida não encontrada."
            : `Falha ao carregar corrida: ${result.reason}`}
        </div>
      </div>
    );
  }

  const delivery = result.delivery as DeliveryDetail;
  return (
    <div className="space-y-4">
      <Link href="/admin/deliveries" className="inline-flex items-center gap-1 text-sm text-primary hover:underline">
        <ArrowLeft className="h-4 w-4" /> Corridas
      </Link>
      <DeliveryDetailTabs delivery={delivery} />
    </div>
  );
}