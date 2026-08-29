import { handleInternalPost } from "@/lib/api/internal-handler";
import { validateCreateDelivery, createDelivery, type CreateDeliveryInput } from "@/lib/services/deliveries";

/**
 * `POST /api/internal/deliveries` → `create_delivery_request` (ADR-011).
 * Cria em `draft` + itens + evento `delivery_created`; **sem preço**.
 * Dedup de criação por `external_reference` é interna da RPC (on conflict, 0021:140);
 * o ledger é defesa em profundidade + replay (ADR-019 D4).
 */
export async function POST(request: Request): Promise<Response> {
  return handleInternalPost(request, {
    eventType: "delivery.create",
    source: "internal-api",
    validate: (b) => {
      const r = validateCreateDelivery(b);
      return r.valid ? null : r.reason;
    },
    run: (correlationId, body) => createDelivery(body as CreateDeliveryInput, correlationId),
  });
}