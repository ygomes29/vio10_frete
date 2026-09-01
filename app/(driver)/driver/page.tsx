import { redirect } from "next/navigation";
import { getDriverContext } from "@/lib/server/driver-context";
import { getDriverMe, getActiveDelivery } from "@/lib/services/driver-reads";
import { AvailabilityToggle } from "@/components/driver/availability-toggle";
import { OpportunityPanel } from "@/components/driver/opportunity-panel";
import { ActiveDeliveryCard } from "@/components/driver/active-delivery-card";
import { LocationTracker } from "@/components/driver/location-tracker";

type Me = {
  id: string;
  full_name: string;
  current_availability_status: string;
};
type ActiveRow = {
  delivery_request_id: string;
  status: string;
  delivery_requests: {
    id: string;
    status: string;
    pickup_address: string;
    delivery_address: string;
  };
  delivery_offers?: { driver_offer_cents?: number | null } | null;
  bids?: { bid_amount_cents?: number | null } | null;
};

/**
 * Home do entregador (ADR-023 Fase 4 / D7). Server Component: lê `me` + corrida
 * ativa via RLS (cookie JWT). Frontend só apresenta estado oficial — nunca inventa.
 * - Corrida ativa → card → detalhe (máquina de estados) + telemetria on.
 * - Senão → toggle de disponibilidade + painel de oportunidades (polling).
 */
export default async function DriverHomePage() {
  const ctx = await getDriverContext();
  if (!ctx) redirect("/auth/login");

  const meRes = await getDriverMe(ctx.client, ctx.driverId);
  const activeRes = await getActiveDelivery(ctx.client, ctx.driverId);

  const me = meRes.ok ? (meRes as unknown as Me) : null;
  const active = activeRes.ok
    ? ((activeRes as unknown as { active: ActiveRow | null }).active ?? null)
    : null;

  const driverName = me?.full_name ?? "Entregador";
  const status = (me?.current_availability_status ?? "offline") as
    | "offline"
    | "available"
    | "offered"
    | "busy"
    | "paused";

  const activePrice =
    active?.bids && !Array.isArray(active.bids)
      ? active.bids.bid_amount_cents
      : active?.delivery_offers && !Array.isArray(active.delivery_offers)
        ? active.delivery_offers.driver_offer_cents
        : null;

  return (
    <div className="space-y-4">
      <LocationTracker enabled={!!active} />

      <div>
        <h1 className="text-lg font-semibold">{driverName}</h1>
        <p className="text-sm text-muted-foreground">
          {active ? "Você está em corrida" : "Bem-vindo de volta"}
        </p>
      </div>

      {active ? (
        <ActiveDeliveryCard
          active={{
            delivery_request_id: active.delivery_request_id,
            status: active.delivery_requests.status,
            price_cents: activePrice ?? null,
            pickup_address: active.delivery_requests.pickup_address,
            delivery_address: active.delivery_requests.delivery_address,
          }}
        />
      ) : (
        <>
          <AvailabilityToggle driverId={ctx.driverId} initialStatus={status} />
          <OpportunityPanel driverId={ctx.driverId} />
        </>
      )}
    </div>
  );
}