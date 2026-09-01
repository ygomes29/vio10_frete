"use client";

import { useState, useTransition } from "react";
import { apiPost } from "@/lib/client/fetcher";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { CircleDot, Pause, Power } from "lucide-react";

type Status = "offline" | "available" | "offered" | "busy" | "paused";

/** Toggle de disponibilidade (ADR-023 Fase 4). Driver self-toggle: available /
 * paused / offline. `offered`/`busy` são system-set (dispatch) — só pode sair
 * (offline) ou aguardar. POST /api/driver/availability (cookie JWT, RLS). */
export function AvailabilityToggle({
  driverId,
  initialStatus,
}: {
  driverId: string;
  initialStatus: Status;
}) {
  const [status, setStatus] = useState<Status>(initialStatus);
  const [pending, start] = useTransition();
  const [error, setError] = useState<string | null>(null);

  const change = (next: "available" | "paused" | "offline") =>
    start(async () => {
      setError(null);
      const r = await apiPost("/api/driver/availability", { driver_id: driverId, status: next });
      if (r.ok) setStatus(next);
      else setError(r.reason === "not_authorized" ? "Sem permissão." : "Falha ao atualizar.");
    });

  const label: Record<Status, string> = {
    offline: "Offline",
    available: "Disponível",
    offered: "Oportunidade recebida",
    busy: "Em corrida",
    paused: "Pausado",
  };
  const variant: Record<Status, "secondary" | "success" | "default" | "warning"> = {
    offline: "secondary",
    available: "success",
    offered: "default",
    busy: "default",
    paused: "warning",
  };

  const locked = status === "offered" || status === "busy";

  return (
    <Card>
      <CardContent className="flex flex-col gap-4 p-5">
        <div className="flex items-center justify-between">
          <span className="text-sm text-muted-foreground">Status</span>
          <Badge variant={variant[status]}>{label[status]}</Badge>
        </div>
        {locked ? (
          <p className="text-sm text-muted-foreground">
            {status === "offered"
              ? "Você tem uma oportunidade abaixo. Responda antes de mudar o status."
              : "Você está em corrida. Conclua-a para voltar a ficar disponível."}
          </p>
        ) : null}
        <div className="grid grid-cols-3 gap-2">
          <Button
            variant={status === "available" ? "success" : "outline"}
            disabled={pending || locked}
            onClick={() => change("available")}
            className="flex flex-col gap-1 h-auto py-3"
          >
            <CircleDot />
            <span className="text-xs">Disponível</span>
          </Button>
          <Button
            variant={status === "paused" ? "warning" : "outline"}
            disabled={pending || locked}
            onClick={() => change("paused")}
            className="flex flex-col gap-1 h-auto py-3"
          >
            <Pause />
            <span className="text-xs">Pausar</span>
          </Button>
          <Button
            variant={status === "offline" ? "secondary" : "outline"}
            disabled={pending}
            onClick={() => change("offline")}
            className="flex flex-col gap-1 h-auto py-3"
          >
            <Power />
            <span className="text-xs">Offline</span>
          </Button>
        </div>
        {error ? <p className="text-sm text-destructive">{error}</p> : null}
      </CardContent>
    </Card>
  );
}