"use client";

import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";
import { Badge } from "@/components/ui/badge";
import { Card } from "@/components/ui/card";
import { DeliveryTimeline, type TimelineEvent } from "./delivery-timeline";
import { DeliveryMap } from "./delivery-map";
import { statusBadge } from "@/lib/admin/status";
import { formatBRL, formatDistance, formatDuration } from "@/lib/utils";

/**
 * Detalhe da corrida em abas (Sessão 18 / ADR-024 D7). Client (Tabs precisa de
 * state). Renderiza estado oficial recebido do Server Component (`getDeliveryDetail`).
 * Mapa é client-only (Leaflet). Nada é inventado no client (regra mestra).
 */
type Quote = {
  customer_price_cents?: number | null;
  driver_offer_cents?: number | null;
  base_cents?: number | null;
  distance_component_cents?: number | null;
  vehicle_component_cents?: number | null;
  urgency_component_cents?: number | null;
  dynamic_component_cents?: number | null;
  subtotal_cents?: number | null;
  platform_fee_cents?: number | null;
  distance_meters?: number | null;
  duration_seconds?: number | null;
  status?: string | null;
  min_customer_price_cents?: number | null;
  max_customer_price_cents?: number | null;
  min_driver_offer_cents?: number | null;
  max_driver_offer_cents?: number | null;
};
type Item = { id: string; description: string; quantity: number; weight_g?: number | null; notes?: string | null };
type Offer = {
  id: string;
  driver_offer_cents: number;
  status: string;
  expires_at: string;
  created_at: string;
  responded_at: string | null;
  drivers?: { full_name?: string | null } | { full_name?: string | null }[] | null;
  bids?: { id: string; response_type: string; bid_amount_cents: number | null; created_at: string }[] | null;
};
type Assignment = {
  id: string;
  status: string;
  assigned_at: string;
  ended_at: string | null;
  ended_reason: string | null;
  drivers?: {
    full_name?: string | null;
    phone?: string | null;
    vehicles?: { plate?: string | null; model?: string | null; vehicle_type?: string | null } | null;
  } | null;
};
type Round = {
  id: string;
  round_number: number;
  status: string;
  search_radius_m: number;
  max_candidates: number;
  driver_offer_cents: number;
  opened_at: string;
  closed_at: string | null;
  expires_at: string;
};

export type DeliveryDetail = {
  id: string;
  status: string;
  external_reference?: string | null;
  created_at: string;
  assigned_at?: string | null;
  picked_up_at?: string | null;
  in_transit_at?: string | null;
  delivered_at?: string | null;
  cancelled_at?: string | null;
  cancelled_reason?: string | null;
  failed_reason?: string | null;
  scheduled_at?: string | null;
  vehicle_required: string;
  pickup_address: string;
  pickup_latitude: number;
  pickup_longitude: number;
  pickup_contact_name?: string | null;
  pickup_contact_phone?: string | null;
  delivery_address: string;
  delivery_latitude: number;
  delivery_longitude: number;
  delivery_contact_name?: string | null;
  delivery_contact_phone?: string | null;
  instructions?: string | null;
  notes?: string | null;
  businesses?: { name?: string | null } | null;
  delivery_quotes?: Quote | Quote[] | null;
  delivery_items?: Item[] | null;
  delivery_events?: TimelineEvent[] | null;
  proof_of_delivery?: unknown[] | null;
  dispatch_rounds?: Round[] | null;
  delivery_offers?: Offer[] | null;
  delivery_assignments?: Assignment[] | Assignment | null;
};

function asArray<T>(x: T | T[] | null | undefined): T[] {
  if (x == null) return [];
  return Array.isArray(x) ? x : [x];
}

function fmt(s: string | null | undefined): string {
  if (!s) return "—";
  return new Date(s).toLocaleString("pt-BR");
}

export function DeliveryDetailTabs({
  delivery,
  positionsUrl,
}: {
  delivery: DeliveryDetail;
  /** URL de polling das posições p/ o mapa (default `/api/admin/deliveries/{id}/positions`).
   *  Sessão 19: parametrizado p/ reuso no portal business. */
  positionsUrl?: string;
}) {
  const b = statusBadge(delivery.status);
  const quote = asArray(delivery.delivery_quotes)[0];
  const items = delivery.delivery_items ?? [];
  const events = delivery.delivery_events ?? [];
  const offers = delivery.delivery_offers ?? [];
  const rounds = delivery.dispatch_rounds ?? [];
  const assignment = asArray(delivery.delivery_assignments)[0];

  return (
    <Tabs defaultValue="summary" className="w-full">
      <TabsList>
        <TabsTrigger value="summary">Resumo</TabsTrigger>
        <TabsTrigger value="timeline">Timeline ({events.length})</TabsTrigger>
        <TabsTrigger value="map">Mapa</TabsTrigger>
        <TabsTrigger value="offers">Ofertas ({offers.length})</TabsTrigger>
      </TabsList>

      <TabsContent value="summary">
        <div className="grid gap-4 md:grid-cols-2">
          <Card className="p-4 space-y-2 text-sm">
            <div className="flex items-center gap-2">
              <Badge variant={b.variant}>{b.label}</Badge>
              <span className="font-mono text-xs text-muted-foreground">{delivery.id.slice(0, 8)}</span>
            </div>
            <Row label="Empresa" value={delivery.businesses?.name ?? "—"} />
            <Row label="Veículo" value={delivery.vehicle_required.toUpperCase()} />
            <Row label="Criada" value={fmt(delivery.created_at)} />
            <Row label="Atribuída" value={fmt(delivery.assigned_at)} />
            <Row label="Coletada" value={fmt(delivery.picked_up_at)} />
            <Row label="Em trânsito" value={fmt(delivery.in_transit_at)} />
            <Row label="Entregue" value={fmt(delivery.delivered_at)} />
            {delivery.cancelled_reason && <Row label="Cancelada" value={delivery.cancelled_reason} />}
            {delivery.failed_reason && <Row label="Falha" value={delivery.failed_reason} />}
          </Card>

          <Card className="p-4 space-y-2 text-sm">
            <h3 className="font-semibold">Coleta</h3>
            <Row label="Endereço" value={delivery.pickup_address} />
            <Row label="Contato" value={[delivery.pickup_contact_name, delivery.pickup_contact_phone].filter(Boolean).join(" · ") || "—"} />
            <h3 className="mt-3 font-semibold">Entrega</h3>
            <Row label="Endereço" value={delivery.delivery_address} />
            <Row label="Contato" value={[delivery.delivery_contact_name, delivery.delivery_contact_phone].filter(Boolean).join(" · ") || "—"} />
            {delivery.instructions && <Row label="Instruções" value={delivery.instructions} />}
            {delivery.notes && <Row label="Notas" value={delivery.notes} />}
          </Card>

          {quote && (
            <Card className="p-4 space-y-2 text-sm">
              <h3 className="font-semibold">Cotação</h3>
              <Row label="Cliente" value={formatBRL(quote.customer_price_cents)} />
              <Row label="Entregador" value={formatBRL(quote.driver_offer_cents)} />
              <Row label="Faixa cliente" value={`${formatBRL(quote.min_customer_price_cents)} – ${formatBRL(quote.max_customer_price_cents)}`} />
              <Row label="Faixa entregador" value={`${formatBRL(quote.min_driver_offer_cents)} – ${formatBRL(quote.max_driver_offer_cents)}`} />
              <Row label="Distância" value={formatDistance(quote.distance_meters)} />
              <Row label="Duração" value={formatDuration(quote.duration_seconds)} />
              <Row label="Base" value={formatBRL(quote.base_cents)} />
              <Row label="Distância (comp.)" value={formatBRL(quote.distance_component_cents)} />
              <Row label="Veículo (comp.)" value={formatBRL(quote.vehicle_component_cents)} />
              <Row label="Urgência (comp.)" value={formatBRL(quote.urgency_component_cents)} />
              <Row label="Plataforma (fee)" value={formatBRL(quote.platform_fee_cents)} />
              <Row label="Status quote" value={quote.status ?? "—"} />
            </Card>
          )}

          <Card className="p-4 space-y-2 text-sm">
            <h3 className="font-semibold">Itens</h3>
            {items.length === 0 ? (
              <p className="text-muted-foreground">Sem itens.</p>
            ) : (
              <ul className="space-y-1">
                {items.map((it) => (
                  <li key={it.id} className="flex justify-between gap-2">
                    <span className="truncate">
                      {it.quantity}× {it.description}
                    </span>
                    <span className="text-muted-foreground">{it.weight_g ? `${it.weight_g} g` : ""}</span>
                  </li>
                ))}
              </ul>
            )}
            {assignment?.drivers && (
              <>
                <h3 className="mt-3 font-semibold">Entregador</h3>
                <Row label="Nome" value={assignment.drivers.full_name ?? "—"} />
                <Row label="Telefone" value={assignment.drivers.phone ?? "—"} />
                {assignment.drivers.vehicles && (
                  <Row
                    label="Veículo"
                    value={[assignment.drivers.vehicles.plate, assignment.drivers.vehicles.model].filter(Boolean).join(" · ") || "—"}
                  />
                )}
                <Row label="Status assignment" value={assignment.status} />
              </>
            )}
          </Card>
        </div>
      </TabsContent>

      <TabsContent value="timeline">
        <Card className="p-4">
          <DeliveryTimeline events={events} />
        </Card>
      </TabsContent>

      <TabsContent value="map">
        <Card className="p-2">
          <DeliveryMap
            deliveryId={delivery.id}
            pickup={{ lat: delivery.pickup_latitude, lng: delivery.pickup_longitude }}
            delivery={{ lat: delivery.delivery_latitude, lng: delivery.delivery_longitude }}
            positionsUrl={positionsUrl}
          />
        </Card>
      </TabsContent>

      <TabsContent value="offers">
        <div className="space-y-4">
          {offers.length === 0 && <p className="text-sm text-muted-foreground">Nenhuma oferta.</p>}
          {offers.map((o) => {
            const dr = o.drivers;
            const d = Array.isArray(dr) ? dr[0] : dr;
            const bids = o.bids ?? [];
            return (
              <Card key={o.id} className="p-4 space-y-2 text-sm">
                <div className="flex items-center justify-between">
                  <span className="font-medium">{d?.full_name ?? "Entregador"}</span>
                  <Badge variant="secondary">{o.status}</Badge>
                </div>
                <Row label="Oferta" value={formatBRL(o.driver_offer_cents)} />
                <Row label="Expira" value={fmt(o.expires_at)} />
                <Row label="Respondida" value={fmt(o.responded_at)} />
                {bids.length > 0 && (
                  <div className="pt-2">
                    <p className="text-xs font-semibold text-muted-foreground">Lances</p>
                    <ul className="mt-1 space-y-1">
                      {bids.map((bi) => (
                        <li key={bi.id} className="flex justify-between">
                          <span className="uppercase text-xs">{bi.response_type}</span>
                          <span>{formatBRL(bi.bid_amount_cents)}</span>
                        </li>
                      ))}
                    </ul>
                  </div>
                )}
              </Card>
            );
          })}
          {rounds.length > 0 && (
            <Card className="p-4 space-y-2 text-sm">
              <h3 className="font-semibold">Rodadas de dispatch</h3>
              <ul className="space-y-1">
                {rounds.map((r) => (
                  <li key={r.id} className="flex justify-between gap-2">
                    <span>Rodada {r.round_number}</span>
                    <Badge variant="outline">{r.status}</Badge>
                    <span className="text-muted-foreground">raio {r.search_radius_m} m</span>
                    <span>{formatBRL(r.driver_offer_cents)}</span>
                  </li>
                ))}
              </ul>
            </Card>
          )}
        </div>
      </TabsContent>
    </Tabs>
  );
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex justify-between gap-2">
      <span className="text-muted-foreground">{label}</span>
      <span className="text-right">{value}</span>
    </div>
  );
}