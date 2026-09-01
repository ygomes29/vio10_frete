import type { badgeVariants } from "@/components/ui/badge";
import type { VariantProps } from "class-variance-authority";

type BadgeVariant = NonNullable<VariantProps<typeof badgeVariants>["variant"]>;

/**
 * Mapeia `delivery_status` → {label, variant} p/ badges do dashboard admin
 * (Sessão 18 / ADR-024 D0). Estados ativos em laranja de marca (primary), terminais
 * com cores semânticas (success/destructive/warning). Sem enum importado do DB —
 * strings alinhadas às migrations (0002) + ADR-016.
 */
const STATUS_LABEL: Record<string, string> = {
  draft: "Rascunho",
  quoted: "Cotada",
  searching_driver: "Buscando entregador",
  assigned: "Atribuída",
  driver_to_pickup: "A caminho da coleta",
  at_pickup: "Na coleta",
  picked_up: "Coletada",
  in_transit: "Em trânsito",
  delivered: "Entregue",
  cancelled: "Cancelada",
  failed: "Falhou",
  expired: "Expirada",
};

function statusVariant(status: string): BadgeVariant {
  switch (status) {
    case "delivered":
      return "success";
    case "cancelled":
    case "failed":
    case "expired":
      return "destructive";
    case "searching_driver":
      return "warning";
    case "assigned":
    case "driver_to_pickup":
    case "at_pickup":
    case "picked_up":
    case "in_transit":
      return "default"; // laranja de marca (primary)
    default:
      return "secondary";
  }
}

export function statusBadge(status: string): { label: string; variant: BadgeVariant } {
  return { label: STATUS_LABEL[status] ?? status, variant: statusVariant(status) };
}

/** `drivers.current_availability_status` → badge (0005). */
const AVAIL_LABEL: Record<string, string> = {
  online: "Online",
  available: "Disponível",
  busy: "Ocupado",
  offline: "Offline",
};

export function availabilityBadge(status: string): { label: string; variant: BadgeVariant } {
  const variant: BadgeVariant =
    status === "online" || status === "available"
      ? "success"
      : status === "busy"
        ? "default"
        : "secondary";
  return { label: AVAIL_LABEL[status] ?? status, variant };
}

/**
 * Label amigável p/ `delivery_event_type` (0002 + 0025 + 0027 — **24 tipos
 * válidos**, conferidos live no enum do dev: `delivery_created, quote_created,
 * quote_confirmed, dispatch_started, round_opened, offer_created, offer_accepted,
 * counter_bid_received, offer_declined, round_closed, winner_selected,
 * driver_assigned, assignment_superseded, driver_to_pickup, arrived_at_pickup,
 * picked_up, in_transit, delivered, cancelled, failed, expired, pod_submitted,
 * otp_generated`). Fallback retorna o próprio tipo (não crasha).
 */
const EVENT_LABEL: Record<string, string> = {
  delivery_created: "Corrida criada",
  quote_created: "Cotação gerada",
  quote_confirmed: "Cotação confirmada",
  dispatch_started: "Dispatch iniciado",
  round_opened: "Rodada de dispatch aberta",
  offer_created: "Oferta enviada",
  offer_accepted: "Oferta aceita (ACEITAR)",
  counter_bid_received: "Lance recebido",
  offer_declined: "Oferta recusada",
  round_closed: "Rodada fechada",
  winner_selected: "Vencedor selecionado",
  driver_assigned: "Entregador atribuído",
  assignment_superseded: "Atribuição substituída",
  driver_to_pickup: "A caminho da coleta",
  arrived_at_pickup: "Chegou na coleta",
  picked_up: "Pedido coletado",
  in_transit: "Em trânsito",
  delivered: "Entregue",
  cancelled: "Cancelada",
  failed: "Falhou",
  expired: "Expirada",
  pod_submitted: "POD submetido",
  otp_generated: "OTP gerado",
};

export function eventLabel(type: string): string {
  return EVENT_LABEL[type] ?? type;
}