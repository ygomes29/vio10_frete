import { Badge } from "@/components/ui/badge";
import { eventLabel } from "@/lib/admin/status";

/**
 * Timeline da corrida — `delivery_events` (Sessão 18 / ADR-024 D7). Presentacional.
 * Eventos já ordenados por `created_at` no service. 23 tipos (0002 + 0025 + 0027).
 */
export type TimelineEvent = {
  id: string;
  event_type: string;
  actor_type: string;
  actor_id: string | null;
  from_status: string | null;
  to_status: string | null;
  metadata: Record<string, unknown> | null;
  correlation_id: string | null;
  created_at: string;
};

export function DeliveryTimeline({ events }: { events: TimelineEvent[] }) {
  if (!events || events.length === 0) {
    return <p className="text-sm text-muted-foreground">Sem eventos registrados.</p>;
  }
  return (
    <ol className="relative space-y-4 border-l pl-4">
      {events.map((e) => (
        <li key={e.id} className="relative">
          <span className="absolute -left-[21px] top-1 h-2.5 w-2.5 rounded-full bg-primary" />
          <div className="flex items-center justify-between gap-2">
            <span className="text-sm font-medium">{eventLabel(e.event_type)}</span>
            <span className="text-xs text-muted-foreground">
              {new Date(e.created_at).toLocaleString("pt-BR")}
            </span>
          </div>
          <div className="mt-1 flex flex-wrap items-center gap-1.5 text-xs text-muted-foreground">
            <Badge variant="outline" className="font-mono text-[10px]">
              {e.actor_type}
            </Badge>
            {e.from_status && e.to_status && (
              <span>
                {e.from_status} → <span className="font-medium text-foreground">{e.to_status}</span>
              </span>
            )}
          </div>
          {e.metadata && Object.keys(e.metadata).length > 0 && (
            <pre className="mt-2 max-h-40 overflow-auto rounded bg-muted p-2 text-[11px]">
              {JSON.stringify(e.metadata, null, 2)}
            </pre>
          )}
        </li>
      ))}
    </ol>
  );
}