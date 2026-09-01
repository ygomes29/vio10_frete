"use client";

import { useCallback, useEffect, useState, useTransition } from "react";
import { apiPost, apiGet } from "@/lib/client/fetcher";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Badge } from "@/components/ui/badge";
import { Navigation, MapPin, PackageCheck, Truck, CheckCircle2, Loader2, ShieldCheck } from "lucide-react";

type Status =
  | "assigned"
  | "driver_to_pickup"
  | "at_pickup"
  | "picked_up"
  | "in_transit"
  | "delivered";

const STEP_ORDER: Status[] = [
  "assigned",
  "driver_to_pickup",
  "at_pickup",
  "picked_up",
  "in_transit",
  "delivered",
];

const STEP_LABEL: Record<Status, string> = {
  assigned: "Atribuída",
  driver_to_pickup: "A caminho da coleta",
  at_pickup: "No local de coleta",
  picked_up: "Mercadoria coletada",
  in_transit: "A caminho da entrega",
  delivered: "Entregue",
};

/**
 * Máquina de estados da corrida (ADR-023 Fase 4 / D7, ADR-016 D1, ADR-017).
 * Driver só faz as 4 transições pós-assigned (`transition_delivery`). `delivered`
 * é **system** via `confirm_delivery` após o POD de entrega (`pod_submitted`) —
 * o driver **não** marca delivered (análogo a ACEITAR ≠ GANHAR: Submete POD ≠
 * entregue). Pickup POD é gate para `picked_up` (ADR-017 D3).
 *
 * Polling GET /api/driver/deliveries/active ~10s (foreground) reflete o estado
 * oficial — se o sistema mover para `delivered`, a UI acompanha.
 * Idempotência real é do backend (RPC); o disable na UI é UX (ADR-020 D7).
 */
export function DeliveryStateMachine({
  deliveryId,
  initialStatus,
  initialPickupPod,
  initialDeliveryPod,
}: {
  deliveryId: string;
  initialStatus: Status;
  initialPickupPod: boolean;
  initialDeliveryPod: boolean;
}) {
  const [status, setStatus] = useState<Status>(initialStatus);
  const [pickupPod, setPickupPod] = useState(initialPickupPod);
  const [deliveryPod, setDeliveryPod] = useState(initialDeliveryPod);
  const [pending, start] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [notes, setNotes] = useState("");
  const [receiverName, setReceiverName] = useState("");
  const [otpCode, setOtpCode] = useState("");

  // Polling do estado oficial (foreground). Atualiza se o sistema moveu (ex.: delivered).
  const refresh = useCallback(async () => {
    const r = await apiGet<{
      active?: {
        delivery_request_id: string;
        delivery_requests?: { status?: Status };
        proof_of_delivery?: { pod_type: string }[];
      } | null;
    }>("/api/driver/deliveries/active");
    const a = r.data?.active;
    if (a && a.delivery_request_id === deliveryId) {
      const s = a.delivery_requests?.status;
      if (s) setStatus(s);
      const pods = a.proof_of_delivery ?? [];
      setPickupPod(pods.some((p) => p.pod_type === "pickup"));
      setDeliveryPod(pods.some((p) => p.pod_type === "delivery"));
    }
  }, [deliveryId]);

  useEffect(() => {
    if (status === "delivered") return;
    const id = window.setInterval(refresh, 10_000);
    return () => window.clearInterval(id);
  }, [refresh, status]);

  const transition = (toStatus: Status) => {
    setError(null);
    start(async () => {
      const r = await apiPost(
        `/api/driver/deliveries/${deliveryId}/transitions`,
        { to_status: toStatus },
        { idempotencyKey: `transition-${deliveryId}-${toStatus}` },
      );
      if (r.ok) {
        setStatus(toStatus);
      } else {
        setError(humanReason(r.reason));
      }
    });
  };

  const submitPickupPod = () => {
    if (!notes.trim()) {
      setError("Adicione uma observação da coleta.");
      return;
    }
    setError(null);
    start(async () => {
      const r = await apiPost(
        `/api/driver/deliveries/${deliveryId}/pod`,
        { pod_type: "pickup", notes: notes.trim() },
        { idempotencyKey: `pod-pickup-${deliveryId}` },
      );
      if (r.ok) {
        setPickupPod(true);
        setNotes("");
      } else {
        setError(humanReason(r.reason));
      }
    });
  };

  const submitDeliveryPod = () => {
    if (!receiverName.trim() || !otpCode.trim()) {
      setError("Informe o nome do recebedor e o código OTP que ele recebeu.");
      return;
    }
    setError(null);
    start(async () => {
      const r = await apiPost(
        `/api/driver/deliveries/${deliveryId}/pod`,
        { pod_type: "delivery", receiver_name: receiverName.trim(), otp_code: otpCode.trim() },
        { idempotencyKey: `pod-delivery-${deliveryId}` },
      );
      if (r.ok) {
        setDeliveryPod(true);
        setOtpCode("");
        // Não setamos delivered — o sistema confirma via confirm_delivery.
        // O polling trará `delivered` quando o sistema concluir.
      } else {
        setError(humanReason(r.reason));
      }
    });
  };

  const currentIdx = STEP_ORDER.indexOf(status);

  return (
    <div className="space-y-4">
      {/* Stepper */}
      <div className="flex items-center justify-between gap-1">
        {STEP_ORDER.map((s, i) => (
          <div key={s} className="flex flex-1 flex-col items-center gap-1">
            <div
              className={`flex size-7 items-center justify-center rounded-full text-xs font-semibold ${
                i < currentIdx
                  ? "bg-success text-success-foreground"
                  : i === currentIdx
                    ? "bg-primary text-primary-foreground"
                    : "bg-muted text-muted-foreground"
              }`}
            >
              {i < currentIdx ? <CheckCircle2 className="size-4" /> : i + 1}
            </div>
            <span className="hidden text-[10px] leading-tight text-muted-foreground sm:block">
              {STEP_LABEL[s]}
            </span>
          </div>
        ))}
      </div>

      <Card>
        <CardContent className="space-y-4 p-4">
          <div className="flex items-center justify-between">
            <Badge variant="default">{STEP_LABEL[status]}</Badge>
            {pending ? <Loader2 className="size-4 animate-spin text-muted-foreground" /> : null}
          </div>

          {/* assigned */}
          {status === "assigned" ? (
            <ActionButton
              icon={<Navigation />}
              label="Ir para a coleta"
              disabled={pending}
              onClick={() => transition("driver_to_pickup")}
            />
          ) : null}

          {/* driver_to_pickup */}
          {status === "driver_to_pickup" ? (
            <ActionButton
              icon={<MapPin />}
              label="Cheguei na coleta"
              disabled={pending}
              onClick={() => transition("at_pickup")}
            />
          ) : null}

          {/* at_pickup */}
          {status === "at_pickup" ? (
            <div className="space-y-3">
              <p className="text-sm text-muted-foreground">
                Registre a prova de coleta para liberar a coleta da mercadoria.
              </p>
              {pickupPod ? (
                <Badge variant="success" className="gap-1">
                  <ShieldCheck /> Prova de coleta registrada
                </Badge>
              ) : (
                <div className="space-y-2 rounded-lg border p-3">
                  <Label htmlFor="pickup-notes">Observação da coleta</Label>
                  <Input
                    id="pickup-notes"
                    placeholder="Ex.: pacote retirado com o porteiro"
                    value={notes}
                    onChange={(e) => setNotes(e.target.value)}
                  />
                  <Button size="sm" disabled={pending} onClick={submitPickupPod}>
                    <PackageCheck /> Registrar prova de coleta
                  </Button>
                </div>
              )}
              <ActionButton
                icon={<PackageCheck />}
                label="Mercadoria coletada"
                variant="success"
                disabled={pending || !pickupPod}
                onClick={() => transition("picked_up")}
              />
              {!pickupPod ? (
                <p className="text-xs text-muted-foreground">
                  Registre a prova de coleta antes de confirmar a coleta.
                </p>
              ) : null}
            </div>
          ) : null}

          {/* picked_up */}
          {status === "picked_up" ? (
            <ActionButton
              icon={<Truck />}
              label="Iniciar entrega"
              variant="success"
              disabled={pending}
              onClick={() => transition("in_transit")}
            />
          ) : null}

          {/* in_transit */}
          {status === "in_transit" ? (
            <div className="space-y-3">
              <p className="text-sm text-muted-foreground">
                Confirme a entrega com o recebedor. Peça o código OTP que ele recebeu
                no WhatsApp.
              </p>
              {deliveryPod ? (
                <div className="space-y-2">
                  <Badge variant="success" className="gap-1">
                    <ShieldCheck /> Prova de entrega registrada
                  </Badge>
                  <p className="text-sm text-muted-foreground">
                    Aguarde — o sistema está confirmando a conclusão da entrega.
                  </p>
                </div>
              ) : (
                <div className="space-y-2 rounded-lg border p-3">
                  <div className="space-y-1">
                    <Label htmlFor="receiver">Nome do recebedor</Label>
                    <Input
                      id="receiver"
                      placeholder="Quem recebeu"
                      value={receiverName}
                      onChange={(e) => setReceiverName(e.target.value)}
                    />
                  </div>
                  <div className="space-y-1">
                    <Label htmlFor="otp">Código OTP (recebedor)</Label>
                    <Input
                      id="otp"
                      inputMode="numeric"
                      maxLength={6}
                      placeholder="000000"
                      value={otpCode}
                      onChange={(e) => setOtpCode(e.target.value.replace(/\D/g, ""))}
                    />
                  </div>
                  <Button variant="success" disabled={pending} onClick={submitDeliveryPod}>
                    <ShieldCheck /> Confirmar entrega
                  </Button>
                </div>
              )}
            </div>
          ) : null}

          {/* delivered */}
          {status === "delivered" ? (
            <div className="flex flex-col items-center gap-2 py-4 text-center">
              <CheckCircle2 className="size-10 text-success" />
              <p className="font-semibold">Entrega concluída!</p>
              <p className="text-sm text-muted-foreground">
                O sistema registrou a conclusão. Você voltará a ficar disponível.
              </p>
            </div>
          ) : null}

          {error ? <p className="text-sm text-destructive">{error}</p> : null}
        </CardContent>
      </Card>
    </div>
  );
}

function ActionButton({
  icon,
  label,
  onClick,
  disabled,
  variant = "default",
}: {
  icon: React.ReactNode;
  label: string;
  onClick: () => void;
  disabled?: boolean;
  variant?: "default" | "success" | "outline";
}) {
  return (
    <Button variant={variant} size="lg" disabled={disabled} onClick={onClick} className="w-full">
      {icon} {label}
    </Button>
  );
}

function humanReason(reason?: string | null): string {
  switch (reason) {
    case "offer_expired":
      return "Oferta vencida.";
    case "already_responded":
    case "offer_already_responded":
      return "Você já respondeu esta oferta.";
    case "invalid_bid_amount":
      return "Lance fora da faixa permitida.";
    case "invalid_transition":
      return "Transição inválida para o estado atual.";
    case "wrong_state":
      return "A corrida não está no estado esperado para esta ação.";
    case "pod_already_submitted":
      return "A prova já foi registrada.";
    case "otp_already_used":
      return "O código OTP já foi utilizado.";
    case "otp_invalid":
    case "invalid_otp":
      return "Código OTP inválido. Peça ao recebedor o código correto.";
    case "pod_required":
      return "É preciso registrar a prova antes de avançar.";
    case "not_authorized":
      return "Sem permissão para esta ação.";
    case "invalid_pod":
      return "Dados da prova inválidos.";
    default:
      return "Não foi possível concluir. Tente novamente.";
  }
}