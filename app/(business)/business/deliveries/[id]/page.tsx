import Link from "next/link";
import { redirect } from "next/navigation";
import { getBusinessContext } from "@/lib/server/business-context";
import { getDeliveryDetail } from "@/lib/services/business-reads";
import { DeliveryDetailTabs, type DeliveryDetail } from "@/components/admin/delivery-detail-tabs";
import { ArrowLeft } from "lucide-react";

export const dynamic = "force-dynamic";

/**
 * `/business/deliveries/{id}` — detalhe da corrida (Sessão 19 / ADR-025 D7). Server
 * Component lê estado oficial via `getBusinessContext()` + `getDeliveryDetail`
 * (user-scoped, RLS `can_view_delivery_request` escopa ao tenant; corrida de outra org
 * → `not_found`) e passa ao client component (Tabs + mapa Leaflet polling posições via
 * endpoint business). Sem `service_role`, read-only.
 */
export default async function BusinessDeliveryDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const ctx = await getBusinessContext();
  if (!ctx) redirect(`/auth/login?redirect=/business/deliveries/${id}`);

  const result = await getDeliveryDetail(ctx.client, id);
  if (!result.ok) {
    return (
      <div className="space-y-4">
        <Link href="/business/deliveries" className="inline-flex items-center gap-1 text-sm text-primary hover:underline">
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
      <Link href="/business/deliveries" className="inline-flex items-center gap-1 text-sm text-primary hover:underline">
        <ArrowLeft className="h-4 w-4" /> Corridas
      </Link>
      <DeliveryDetailTabs
        delivery={delivery}
        positionsUrl={`/api/business/deliveries/${id}/positions`}
      />
    </div>
  );
}