"use client";

import Link from "next/link";
import { Card, CardContent } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { formatBRL } from "@/lib/utils";
import { ArrowRight, MapPin } from "lucide-react";

type Active = {
  delivery_request_id: string;
  status: string;
  price_cents?: number | null;
  pickup_address: string;
  delivery_address: string;
};

const STATUS_LABEL: Record<string, string> = {
  assigned: "Atribuída — ir para coleta",
  driver_to_pickup: "A caminho da coleta",
  at_pickup: "No local de coleta",
  picked_up: "Mercadoria coletada",
  in_transit: "A caminho da entrega",
  delivered: "Entregue",
};

/** Card de corrida ativa na home (ADR-023 Fase 4). Link para o detalhe com a
 * máquina de estados. Frontend só apresenta estado oficial do backend. */
export function ActiveDeliveryCard({ active }: { active: Active }) {
  return (
    <Link href={`/driver/delivery/${active.delivery_request_id}`} className="block">
      <Card className="border-primary/30 transition-colors hover:border-primary/60">
        <CardContent className="space-y-3 p-4">
          <div className="flex items-center justify-between">
            <Badge variant="default">{STATUS_LABEL[active.status] ?? active.status}</Badge>
            {active.price_cents != null ? (
              <span className="font-bold text-success">{formatBRL(active.price_cents)}</span>
            ) : null}
          </div>
          <div className="space-y-1 text-sm">
            <div className="flex items-start gap-2">
              <MapPin className="mt-0.5 size-4 text-muted-foreground" />
              <span>{active.pickup_address}</span>
            </div>
            <div className="flex items-start gap-2">
              <MapPin className="mt-0.5 size-4 text-muted-foreground" />
              <span>{active.delivery_address}</span>
            </div>
          </div>
          <Button variant="outline" size="sm" className="w-full">
            Abrir corrida <ArrowRight />
          </Button>
        </CardContent>
      </Card>
    </Link>
  );
}