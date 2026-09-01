import { redirect } from "next/navigation";
import Link from "next/link";
import { getDriverContext } from "@/lib/server/driver-context";
import { getActiveDelivery } from "@/lib/services/driver-reads";
import { DeliveryStateMachine } from "@/components/driver/delivery-state-machine";
import { LocationTracker } from "@/components/driver/location-tracker";
import { Card, CardContent } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { formatBRL, formatDistance, formatDuration } from "@/lib/utils";
import { ArrowLeft, MapPin, Phone, Package, Clock } from "lucide-react";

type Quote = {
  driver_offer_cents: number;
  distance_meters: number;
  duration_seconds: number;
};
type Item = { id: string; description: string; quantity: number; weight_g?: number | null };
type ActiveFull = {
  delivery_request_id: string;
  delivery_offer_id: string | null;
  bid_id: string | null;
  delivery_requests: {
    id: string;
    status: string;
    pickup_address: string;
    pickup_contact_name: string | null;
    pickup_contact_phone: string | null;
    delivery_address: string;
    delivery_contact_name: string | null;
    delivery_contact_phone: string | null;
    vehicle_required: string;
    scheduled_at: string | null;
    instructions: string | null;
    notes: string | null;
    delivery_quotes: Quote[];
    delivery_items: Item[];
  };
  delivery_offers?: { driver_offer_cents: number | null } | null;
  bids?: { bid_amount_cents: number | null } | null;
  proof_of_delivery?: { pod_type: string }[];
};

/**
 * Detalhe da corrida ativa (ADR-023 Fase 4 / D7). Server Component: lê a corrida
 * ativa via RLS e passa estado oficial + flags de POD para a máquina de estados.
 * Frontend só apresenta; transições e POD vão ao backend (cookie JWT, RPC).
 */
export default async function DeliveryDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const ctx = await getDriverContext();
  if (!ctx) redirect("/auth/login");

  const res = await getActiveDelivery(ctx.client, ctx.driverId);
  if (!res.ok) redirect("/driver");

  const active = (res as unknown as { active: ActiveFull | null }).active;
  if (!active || active.delivery_request_id !== id) redirect("/driver");

  const req = active.delivery_requests;
  const q = req.delivery_quotes?.[0];
  const price =
    active.bids && !Array.isArray(active.bids)
      ? active.bids.bid_amount_cents
      : active.delivery_offers && !Array.isArray(active.delivery_offers)
        ? active.delivery_offers.driver_offer_cents
        : null;
  const pods = active.proof_of_delivery ?? [];
  const hasPickupPod = pods.some((p) => p.pod_type === "pickup");
  const hasDeliveryPod = pods.some((p) => p.pod_type === "delivery");

  return (
    <div className="space-y-4">
      <LocationTracker enabled />

      <Link
        href="/driver"
        className="inline-flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground"
      >
        <ArrowLeft /> Voltar
      </Link>

      <DeliveryStateMachine
        deliveryId={id}
        initialStatus={req.status as never}
        initialPickupPod={hasPickupPod}
        initialDeliveryPod={hasDeliveryPod}
      />

      {/* Resumo */}
      <Card>
        <CardContent className="space-y-4 p-4">
          <div className="flex items-center justify-between">
            <span className="text-sm text-muted-foreground">Valor</span>
            <span className="text-xl font-bold text-success">
              {formatBRL(price ?? q?.driver_offer_cents ?? 0)}
            </span>
          </div>

          <div className="space-y-2 text-sm">
            <div className="flex items-start gap-2">
              <MapPin className="mt-0.5 size-4 text-muted-foreground" />
              <div>
                <div className="text-xs text-muted-foreground">Coleta</div>
                <div>{req.pickup_address}</div>
                {req.pickup_contact_name ? (
                  <div className="text-xs text-muted-foreground">{req.pickup_contact_name}</div>
                ) : null}
              </div>
            </div>
            {req.pickup_contact_phone ? (
              <a
                href={`tel:${req.pickup_contact_phone}`}
                className="inline-flex items-center gap-1 text-sm text-primary"
              >
                <Phone className="size-4" /> {req.pickup_contact_phone}
              </a>
            ) : null}

            <div className="flex items-start gap-2">
              <MapPin className="mt-0.5 size-4 text-muted-foreground" />
              <div>
                <div className="text-xs text-muted-foreground">Entrega</div>
                <div>{req.delivery_address}</div>
                {req.delivery_contact_name ? (
                  <div className="text-xs text-muted-foreground">{req.delivery_contact_name}</div>
                ) : null}
              </div>
            </div>
            {req.delivery_contact_phone ? (
              <a
                href={`tel:${req.delivery_contact_phone}`}
                className="inline-flex items-center gap-1 text-sm text-primary"
              >
                <Phone className="size-4" /> {req.delivery_contact_phone}
              </a>
            ) : null}
          </div>

          <div className="flex flex-wrap gap-2 text-xs">
            <Badge variant="secondary" className="gap-1">
              <Clock /> {formatDuration(q?.duration_seconds)}
            </Badge>
            <Badge variant="secondary" className="gap-1">
              <MapPin /> {formatDistance(q?.distance_meters)}
            </Badge>
            <Badge variant="secondary" className="gap-1">
              <Package />
              {req.vehicle_required === "motorcycle" ? "Moto" : "Carro"}
            </Badge>
          </div>

          {req.delivery_items?.length ? (
            <div className="space-y-1 text-sm">
              <div className="text-xs text-muted-foreground">Itens</div>
              {req.delivery_items.map((it) => (
                <div key={it.id} className="flex justify-between">
                  <span>{it.description}</span>
                  <span className="text-muted-foreground">×{it.quantity}</span>
                </div>
              ))}
            </div>
          ) : null}

          {req.instructions ? (
            <div className="rounded-lg bg-muted/50 p-3 text-sm">
              <div className="text-xs text-muted-foreground">Instruções</div>
              <p>{req.instructions}</p>
            </div>
          ) : null}
        </CardContent>
      </Card>
    </div>
  );
}