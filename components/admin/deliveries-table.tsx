import Link from "next/link";
import { Table, TableHeader, TableBody, TableRow, TableHead, TableCell } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { statusBadge } from "@/lib/admin/status";
import { formatBRL } from "@/lib/utils";

/**
 * Tabela de corridas (Sessão 18 / ADR-024 D7). Presentacional — renderiza rows
 * recebidas do Server Component (estado oficial do backend). Sem "use client".
 */

type Driver = { full_name?: string | null } | { full_name?: string | null }[] | null;
type Assignment = { status?: string; assigned_at?: string; drivers?: Driver } | null;
type Business = { name?: string | null } | null;

export type DeliveryRow = {
  id: string;
  status: string;
  created_at: string;
  assigned_at: string | null;
  picked_up_at: string | null;
  in_transit_at: string | null;
  delivered_at: string | null;
  pickup_address: string;
  delivery_address: string;
  vehicle_required: string;
  businesses?: Business;
  delivery_assignments?: Assignment[] | Assignment;
};

function driverName(a: Assignment): string {
  if (!a) return "—";
  const dr = a.drivers;
  const d = Array.isArray(dr) ? dr[0] : dr;
  return d?.full_name ?? "—";
}

function fmtDate(s: string | null): string {
  if (!s) return "—";
  return new Date(s).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short" });
}

export function DeliveriesTable({ rows }: { rows: DeliveryRow[] }) {
  if (rows.length === 0) {
    return <p className="py-8 text-center text-sm text-muted-foreground">Nenhuma corrida encontrada.</p>;
  }
  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Status</TableHead>
          <TableHead>Coleta</TableHead>
          <TableHead>Entrega</TableHead>
          <TableHead>Empresa</TableHead>
          <TableHead>Entregador</TableHead>
          <TableHead>Criada</TableHead>
          <TableHead>Veículo</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {rows.map((r) => {
          const b = statusBadge(r.status);
          const assignments = r.delivery_assignments;
          const a = Array.isArray(assignments) ? assignments[0] : assignments;
          return (
            <TableRow key={r.id}>
              <TableCell>
                <Link href={`/admin/deliveries/${r.id}`} className="inline-flex flex-col gap-1">
                  <Badge variant={b.variant}>{b.label}</Badge>
                  <span className="font-mono text-[10px] text-muted-foreground">{r.id.slice(0, 8)}</span>
                </Link>
              </TableCell>
              <TableCell className="max-w-[180px] truncate">{r.pickup_address}</TableCell>
              <TableCell className="max-w-[180px] truncate">{r.delivery_address}</TableCell>
              <TableCell className="whitespace-nowrap">{r.businesses?.name ?? "—"}</TableCell>
              <TableCell className="whitespace-nowrap">{driverName(a ?? null)}</TableCell>
              <TableCell className="whitespace-nowrap text-xs text-muted-foreground">{fmtDate(r.created_at)}</TableCell>
              <TableCell className="uppercase text-xs">{r.vehicle_required}</TableCell>
            </TableRow>
          );
        })}
      </TableBody>
    </Table>
  );
}

/** Link de paginação (server-driven via `?offset=`). */
export function Pagination({
  offset,
  limit,
  hasMore,
  basePath,
}: {
  offset: number;
  limit: number;
  hasMore: boolean;
  basePath: string;
}) {
  const prevOffset = Math.max(0, offset - limit);
  const hasPrev = offset > 0;
  return (
    <div className="flex items-center justify-between py-3 text-sm">
      {hasPrev ? (
        <Link className="text-primary hover:underline" href={`${basePath}?offset=${prevOffset}&limit=${limit}`}>
          ‹ Anterior
        </Link>
      ) : (
        <span className="text-muted-foreground">‹ Anterior</span>
      )}
      <span className="text-muted-foreground">
        {offset + 1}–{offset + limit}
      </span>
      {hasMore ? (
        <Link className="text-primary hover:underline" href={`${basePath}?offset=${offset + limit}&limit=${limit}`}>
          Próxima ›
        </Link>
      ) : (
        <span className="text-muted-foreground">Próxima ›</span>
      )}
    </div>
  );
}

// Reexporta formatBRL p/ páginas que precisem (evita import duplicado em consumers).
export { formatBRL };