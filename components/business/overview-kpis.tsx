"use client";

import { useCallback, useEffect, useState } from "react";
import { apiGet } from "@/lib/client/fetcher";
import { formatBRL } from "@/lib/utils";
import { Card } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { statusBadge } from "@/lib/admin/status";
import { Truck, TrendingUp, AlertTriangle } from "lucide-react";

/**
 * Overview KPIs do tenant business (Sessão 19 / ADR-025 D8). Client component — recebe
 * `initial` (SSR via `getBusinessContext`) e faz **polling** `/api/business/overview` a
 * cada 30s em foreground. Sem client Supabase no browser (regra mestra). Só apresenta
 * estado oficial do backend.
 *
 * Diferente do admin: **sem** KPI de entregadores (platform-wide/admin). KPIs do tenant:
 * corridas ativas, entregues hoje (+ volume R$), falhas recentes (últimas 72h).
 */
export type BusinessOverviewData = {
  window_hours?: number;
  deliveries_by_status?: {
    active?: Record<string, number>;
    terminal?: Record<string, number>;
  };
  delivered_today?: { count?: number; total_cents?: number };
  failures?: {
    id: string;
    status: string;
    created_at: string;
    cancelled_at: string | null;
    reason: string | null;
  }[];
};

export function BusinessOverviewKpis({ initial }: { initial: BusinessOverviewData }) {
  const [data, setData] = useState<BusinessOverviewData>(initial);
  const [refreshing, setRefreshing] = useState(false);

  const refresh = useCallback(async () => {
    if (typeof document !== "undefined" && document.visibilityState !== "visible") return;
    setRefreshing(true);
    const r = await apiGet<BusinessOverviewData>("/api/business/overview");
    if (r.ok && r.data) setData(r.data);
    setRefreshing(false);
  }, []);

  useEffect(() => {
    const id = window.setInterval(refresh, 30_000);
    return () => window.clearInterval(id);
  }, [refresh]);

  const active = data.deliveries_by_status?.active ?? {};
  const terminal = data.deliveries_by_status?.terminal ?? {};
  const activeCount = Object.values(active).reduce((a, b) => a + b, 0);
  const failuresCount = Object.values(terminal).reduce((a, b) => a + b, 0);

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-xl font-bold">Visão geral</h1>
        <span className="text-xs text-muted-foreground">
          {refreshing ? "atualizando…" : "atualiza a cada 30s"}
        </span>
      </div>

      <div className="grid gap-4 sm:grid-cols-3">
        <KpiCard icon={<Truck className="h-4 w-4" />} label="Corridas ativas" value={String(activeCount)}>
          <div className="mt-2 flex flex-wrap gap-1">
            {Object.entries(active).map(([s, n]) => {
              const b = statusBadge(s);
              return (
                <Badge key={s} variant={b.variant}>
                  {b.label}: {n}
                </Badge>
              );
            })}
            {activeCount === 0 && <span className="text-xs text-muted-foreground">nenhuma</span>}
          </div>
        </KpiCard>

        <KpiCard
          icon={<TrendingUp className="h-4 w-4" />}
          label="Entregues hoje"
          value={String(data.delivered_today?.count ?? 0)}
        >
          <p className="mt-2 text-sm font-semibold text-primary">
            {formatBRL(data.delivered_today?.total_cents ?? 0)}
          </p>
        </KpiCard>

        <KpiCard icon={<AlertTriangle className="h-4 w-4" />} label="Falhas recentes" value={String(failuresCount)}>
          <p className="mt-2 text-xs text-muted-foreground">últimas 72h</p>
        </KpiCard>
      </div>

      {Array.isArray(data.failures) && data.failures.length > 0 && (
        <Card className="p-4">
          <h2 className="mb-3 text-sm font-semibold">Falhas recentes</h2>
          <ul className="space-y-2">
            {data.failures.slice(0, 10).map((f) => {
              const b = statusBadge(f.status);
              return (
                <li key={f.id} className="flex items-center justify-between gap-2 text-sm">
                  <span className="font-mono text-xs text-muted-foreground">{f.id.slice(0, 8)}</span>
                  <Badge variant={b.variant}>{b.label}</Badge>
                  <span className="flex-1 truncate text-muted-foreground">{f.reason ?? "—"}</span>
                  <span className="text-xs text-muted-foreground">
                    {new Date(f.cancelled_at ?? f.created_at).toLocaleString("pt-BR")}
                  </span>
                </li>
              );
            })}
          </ul>
        </Card>
      )}
    </div>
  );
}

function KpiCard({
  icon,
  label,
  value,
  children,
}: {
  icon: React.ReactNode;
  label: string;
  value: string;
  children?: React.ReactNode;
}) {
  return (
    <Card className="p-4">
      <div className="flex items-center gap-2 text-muted-foreground">
        {icon}
        <span className="text-xs font-medium">{label}</span>
      </div>
      <p className="mt-2 text-2xl font-bold tabular-nums">{value}</p>
      {children}
    </Card>
  );
}