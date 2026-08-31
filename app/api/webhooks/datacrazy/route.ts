import { handleWebhookPost } from "@/lib/api/webhook-handler";
import { captureConversationFromPayload } from "@/lib/api/webhook-conversation-capture";
import { respondToOffer, type RespondOfferInput } from "@/lib/services/driver";
import { createDelivery, generateOtp, type CreateDeliveryInput } from "@/lib/services/deliveries";

/**
 * `POST /api/webhooks/datacrazy` — router de webhooks inbound (ADR-020 D5).
 * Público (sem JWT), protegido por signature HMAC (`x-datacrazy-signature`).
 * Dedup via `webhook_events (source='datacrazy', external_id=x-datacrazy-event-id)`.
 * DataCrazy/IA nunca escreve no banco; o webhook chama services (regra mestra).
 * 200 sempre ao emissor; erros logados + reconciler/DLQ backstop (ADR-018 D7).
 *
 * Intents suportados no MVP:
 *  - `offer_response` → respondToOffer (system-scoped; driver_id do payload).
 *  - `new_request`    → createDelivery (system; cria em draft).
 *  - `otp_request`    → generateOtp (system; gera OTP p/ o recebedor).
 *  - desconhecido     → 200 routed_with_error (DLQ; IA re-pergunta ou reconciler).
 */
export async function POST(request: Request): Promise<Response> {
  return handleWebhookPost(request, {
    source: "datacrazy",
    externalId: (req) => req.headers.get("x-datacrazy-event-id"),
    captureConversation: captureConversationFromPayload,
    route: async (client, payload, correlationId) => {
      const intent = (payload as { intent?: string }).intent;
      switch (intent) {
        case "offer_response": {
          const p = payload as {
            offer_id?: string;
            driver_id?: string;
            response_type?: string;
            bid_amount_cents?: number | null;
          };
          if (!p.offer_id || !p.driver_id || !p.response_type) {
            throw new Error("payload_incompleto: offer_id/driver_id/response_type");
          }
          const input: RespondOfferInput = {
            offerId: p.offer_id,
            driverId: p.driver_id,
            responseType: p.response_type as RespondOfferInput["responseType"],
            bidAmountCents: p.bid_amount_cents ?? null,
          };
          await respondToOffer(client, input, correlationId);
          return;
        }
        case "new_request": {
          await createDelivery(payload as CreateDeliveryInput, correlationId);
          return;
        }
        case "otp_request": {
          const p = payload as { delivery_id?: string };
          if (!p.delivery_id) throw new Error("payload_incompleto: delivery_id");
          await generateOtp(p.delivery_id, {}, correlationId);
          return;
        }
        default:
          // intent desconhecido → lança p/ o handler marcar failed + 200 routed_with_error.
          throw new Error(`unknown_intent: ${intent ?? "(ausente)"}`);
      }
    },
  });
}