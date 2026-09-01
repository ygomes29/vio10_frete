import { redirect } from "next/navigation";
import Link from "next/link";
import { getDriverContext } from "@/lib/server/driver-context";
import { getDeliveryHistory, getEarnings } from "@/lib/services/driver-reads";
import { Card, CardContent } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { formatBRL } from "@/lib/utils";
import { MapPin, TrendingUp, Wallet } from "lucide-react";

type HistoryRow = {
  id: string;
  delivery_request_id: string;
  assigned_at: string;
  ended_at: string | null;
  ended_reason: string | null;
  delivery_requests: {
    id: string;
    status: string;
    pickup_address: string;
    delivery_address: string;
    delivered_at: string | null;
    cancelled_at: string | null;
    cancelled_reason: string | null;
    failed_reason: string | null;
  };
  delivery_offers?: { driver_offer_cents: number | null } | null;
  bids?: { bid_amount_cents: number | null } | null;
};

const STATUS_VARIANT: Record<string, "success" | "destructive" | "warning"> = {
  delivered: "success",
  cancelled: "destructive",
  failed: "destructive",
};

const fmtDate = (iso: string | null) =>
  iso ? new Date(iso).toLocaleDateString("pt-BR", { day: "2-digit", month: "2-digit", year: "numeric" }) : "—";

/**
 * Histórico de corridas + ganhos (ADR-023 Fase 4 / D7). Server Component: lê
 * assignments encerradas + soma de `delivered` (últimos 30d) via RLS. Estado oficial.
 */
export default async function HistoryPage({
  searchParams,
}: {
  searchParams: Promise<{ limit?: string }>;
}) {
  const ctx = await getDriverContext();
  if (!ctx) redirect("/auth/login");

  const sp = await searchParams;
  const limit = Number(sp.limit ?? "20");

  const [histRes, earnRes] = await Promise.all([
    getDeliveryHistory(ctx.client, ctx.driverId, limit),
    getEarnings(ctx.client, ctx.driverId),
  ]);

  const deliveries = histRes.ok ? (histRes as unknown as { deliveries: HistoryRow[] }).deliveries : [];
  const earnings = earnRes.ok
    ? (earnRes as unknown as { total_cents: number; count: number; period_days: number })
    : { total_cents: 0, count: 0, period_days: 30 };

  return (
    <div className="space-y-4">
      <h1 className="text-lg font-semibold">Histórico</h1>

      {/* Ganhos */}
      <Card>
        <CardContent className="space-y-3 p-4">
          <div className="flex items-center gap-2 text-sm text-muted-foreground">
            <Wallet /> Ganhos ({earnings.period_days} dias)
          </div>
          <div className="flex items-end justify-between">
            <span className="text-2xl font-bold text-success">
              {formatBRL(earnings.total_cents)}
            </span>
            <Badge variant="secondary" className="gap-1">
              <TrendingUp /> {earnings.count} entregas
            </Badge>
          </div>
        </CardContent>
      </Card>

      {/* Lista */}
      {deliveries.length === 0 ? (
        <Card>
          <CardContent className="p-6 text-center text-sm text-muted-foreground">
            Nenhuma corrida concluída ainda.
          </CardContent>
        </Card>
      ) : (
        <div className="space-y-2">
          {deliveries.map((d) => {
            const req = d.delivery_requests;
            const price =
              d.bids && !Array.isArray(d.bids)
                ? d.bids.bid_amount_cents
                : d.delivery_offers && !Array.isArray(d.delivery_offers)
                  ? d.delivery_offers.driver_offer_cents
                  : null;
            return (
              <Card key={d.id}>
                <CardContent className="space-y-2 p-4">
                  <div className="flex items-center justify-between">
                    <Badge variant={STATUS_VARIANT[req.status] ?? "secondary"}>
                      {req.status === "delivered"
                        ? "Entregue"
                        : req.status === "cancelled"
                          ? "Cancelada"
                          : req.status === "failed"
                            ? "Falhou"
                            : req.status}
                    </Badge>
                    {price != null ? (
                      <span className="font-semibold">{formatBRL(price)}</span>
                    ) : null}
                  </div>
                  <div className="space-y-1 text-sm">
                    <div className="flex items-start gap-2">
                      <MapPin className="mt-0.5 size-4 text-muted-foreground" />
                      <span className="truncate">{req.pickup_address}</span>
                    </div>
                    <div className="flex items-start gap-2">
                      <MapPin className="mt-0.5 size-4 text-muted-foreground" />
                      <span className="truncate">{req.delivery_address}</span>
                    </div>
                  </div>
                  <div className="flex items-center justify-between text-xs text-muted-foreground">
                    <span>{fmtDate(d.ended_at ?? req.delivered_at ?? d.assigned_at)}</span>
                    {req.cancelled_reason ? <span>{req.cancelled_reason}</span> : null}
                    {req.failed_reason ? <span>{req.failed_reason}</span> : null}
                  </div>
                </CardContent>
              </Card>
            );
          })}
        </div>
      )}

      <Link
        href="/driver"
        className="block pt-2 text-center text-sm text-muted-foreground hover:text-foreground"
      >
        Voltar para o início
      </Link>
    </div>
  );
}