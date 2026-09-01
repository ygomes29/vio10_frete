"use client";

import { useCallback, useEffect, useState, useTransition } from "react";
import { apiGet, apiPost } from "@/lib/client/fetcher";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Badge } from "@/components/ui/badge";
import { formatBRL, formatDistance, formatDuration } from "@/lib/utils";
import { Package, MapPin, Clock, Check, X, TrendingUp, Loader2 } from "lucide-react";

type Quote = {
  driver_offer_cents: number;
  min_driver_offer_cents: number;
  max_driver_offer_cents: number;
  distance_meters: number;
  duration_seconds: number;
};
type Item = { description: string; quantity: number; weight_g?: number | null };
type Opportunity = {
  id: string;
  delivery_request_id: string;
  driver_offer_cents: number;
  expires_at: string;
  created_at: string;
  delivery_requests: {
    id: string;
    pickup_address: string;
    delivery_address: string;
    pickup_contact_name?: string | null;
    vehicle_required: "motorcycle" | "car";
    delivery_quotes: Quote[];
    delivery_items: Item[];
  };
};

/** Painel de oportunidades (ADR-023 Fase 4). Polling GET /api/driver/opportunity ~10s.
 * ACEITAR ≠ GANHAR (ADR-006): aceitar registra lance = driver_offer_cents; a
 * atribuição vem no fechamento da rodada (sistema). RECUSAR descarta. LANCE
 * envia counter_bid dentro da faixa [min,max]. POST /api/offers/{id}/respond. */
export function OpportunityPanel({ driverId }: { driverId: string }) {
  const [opps, setOpps] = useState<Opportunity[]>([]);
  const [loading, setLoading] = useState(true);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [counterFor, setCounterFor] = useState<string | null>(null);
  const [counterValue, setCounterValue] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [, start] = useTransition();

  const refresh = useCallback(async () => {
    const r = await apiGet<{ opportunities?: Opportunity[] }>("/api/driver/opportunity");
    setOpps(r.data?.opportunities ?? []);
    setLoading(false);
  }, []);

  useEffect(() => {
    refresh();
    const id = window.setInterval(refresh, 10_000);
    return () => window.clearInterval(id);
  }, [refresh]);

  const respond = async (
    opp: Opportunity,
    responseType: "accept" | "decline" | "counter_bid",
    bidAmountCents?: number,
  ) => {
    setError(null);
    setBusyId(opp.id);
    start(async () => {
      const r = await apiPost(
        `/api/offers/${opp.id}/respond`,
        { driver_id: driverId, response_type: responseType, bid_amount_cents: bidAmountCents ?? null },
        { idempotencyKey: `respond-${opp.id}` },
      );
      setBusyId(null);
      if (r.ok) {
        setCounterFor(null);
        setCounterValue("");
        refresh();
      } else {
        setError(
          r.reason === "offer_expired"
            ? "Oferta vencida."
            : r.reason === "already_responded" || r.reason === "offer_already_responded"
              ? "Você já respondeu esta oferta."
              : r.reason === "invalid_bid_amount"
                ? "Lance fora da faixa permitida."
                : "Não foi possível responder. Tente novamente.",
        );
      }
    });
  };

  const submitCounter = (opp: Opportunity) => {
    const reais = Number(counterValue.replace(",", "."));
    if (!Number.isFinite(reais)) {
      setError("Informe um valor válido.");
      return;
    }
    const q = opp.delivery_requests.delivery_quotes[0];
    const cents = Math.round(reais * 100);
    if (q && (cents < q.min_driver_offer_cents || cents > q.max_driver_offer_cents)) {
      setError(
        `Lance deve estar entre ${formatBRL(q.min_driver_offer_cents)} e ${formatBRL(q.max_driver_offer_cents)}.`,
      );
      return;
    }
    void respond(opp, "counter_bid", cents);
  };

  if (loading) {
    return (
      <Card>
        <CardContent className="flex items-center justify-center gap-2 p-6 text-muted-foreground">
          <Loader2 className="animate-spin" /> Procurando oportunidades…
        </CardContent>
      </Card>
    );
  }

  if (opps.length === 0) {
    return (
      <Card>
        <CardContent className="p-6 text-center text-muted-foreground">
          Nenhuma oportunidade no momento. Fique disponível para receber ofertas.
        </CardContent>
      </Card>
    );
  }

  return (
    <div className="space-y-3">
      {opps.map((opp) => {
        const q = opp.delivery_requests.delivery_quotes[0];
        const items = opp.delivery_requests.delivery_items;
        const expiresMs = new Date(opp.expires_at).getTime() - Date.now();
        const expiresMin = Math.max(0, Math.round(expiresMs / 60000));
        const isBusy = busyId === opp.id;
        return (
          <Card key={opp.id} className="overflow-hidden">
            <CardHeader className="bg-primary/5 p-4 pb-3">
              <div className="flex items-center justify-between">
                <CardTitle className="text-base">Oportunidade de frete</CardTitle>
                <Badge variant={expiresMin <= 1 ? "destructive" : "warning"}>
                  expira em {expiresMin}min
                </Badge>
              </div>
            </CardHeader>
            <CardContent className="space-y-3 p-4">
              <div className="flex items-center justify-between rounded-lg bg-success/10 px-3 py-2">
                <span className="text-sm text-muted-foreground">Oferta</span>
                <span className="text-xl font-bold text-success">
                  {formatBRL(opp.driver_offer_cents)}
                </span>
              </div>

              <div className="space-y-2 text-sm">
                <div className="flex items-start gap-2">
                  <MapPin className="mt-0.5 size-4 text-muted-foreground" />
                  <div>
                    <div className="text-xs text-muted-foreground">Coleta</div>
                    <div>{opp.delivery_requests.pickup_address}</div>
                  </div>
                </div>
                <div className="flex items-start gap-2">
                  <MapPin className="mt-0.5 size-4 text-muted-foreground" />
                  <div>
                    <div className="text-xs text-muted-foreground">Entrega</div>
                    <div>{opp.delivery_requests.delivery_address}</div>
                  </div>
                </div>
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
                  {opp.delivery_requests.vehicle_required === "motorcycle" ? "Moto" : "Carro"}
                </Badge>
                {items.length > 0 ? (
                  <Badge variant="outline">{items[0].description}{items.length > 1 ? ` +${items.length - 1}` : ""}</Badge>
                ) : null}
              </div>

              {q && q.max_driver_offer_cents > q.min_driver_offer_cents ? (
                <p className="text-xs text-muted-foreground">
                  Faixa de lance: {formatBRL(q.min_driver_offer_cents)} – {formatBRL(q.max_driver_offer_cents)}
                </p>
              ) : null}

              {counterFor === opp.id ? (
                <div className="space-y-2 rounded-lg border p-3">
                  <Label htmlFor={`counter-${opp.id}`}>Seu lance (R$)</Label>
                  <Input
                    id={`counter-${opp.id}`}
                    inputMode="decimal"
                    placeholder="0,00"
                    value={counterValue}
                    onChange={(e) => setCounterValue(e.target.value)}
                  />
                  <div className="flex gap-2">
                    <Button size="sm" disabled={isBusy} onClick={() => submitCounter(opp)}>
                      Enviar lance
                    </Button>
                    <Button
                      size="sm"
                      variant="ghost"
                      onClick={() => {
                        setCounterFor(null);
                        setCounterValue("");
                        setError(null);
                      }}
                    >
                      Cancelar
                    </Button>
                  </div>
                </div>
              ) : (
                <div className="grid grid-cols-3 gap-2">
                  <Button
                    variant="success"
                    disabled={isBusy}
                    onClick={() => respond(opp, "accept")}
                  >
                    <Check /> Aceitar
                  </Button>
                  <Button
                    variant="outline"
                    disabled={isBusy}
                    onClick={() => setCounterFor(opp.id)}
                  >
                    <TrendingUp /> Lance
                  </Button>
                  <Button
                    variant="ghost"
                    disabled={isBusy}
                    onClick={() => respond(opp, "decline")}
                  >
                    <X /> Recusar
                  </Button>
                </div>
              )}
            </CardContent>
          </Card>
        );
      })}
      {error ? <p className="text-sm text-destructive">{error}</p> : null}
    </div>
  );
}