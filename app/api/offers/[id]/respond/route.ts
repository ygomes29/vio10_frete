import { handleOfferRespondPost } from "@/lib/api/offer-respond-handler";
import {
  validateRespondOfferBody,
  respondToOffer,
  type RespondOfferInput,
} from "@/lib/services/driver";
import { createSystemClient } from "@/lib/supabase/system-client";
import { createServerClient } from "@/lib/supabase/server-client";

/**
 * `POST /api/offers/{id}/respond` → `respond_to_offer` (ADR-020 D1, ADR-006).
 * **Dual auth**: cookie JWT (PWA logado, user-scoped) **ou** signed link HMAC
 * (WhatsApp, system-scoped). ACEITAR ≠ GANHAR — não atribui; SWAC decide.
 * Idempotência interna da RPC (D7): `(offer,driver)` unique + `idempotency_key`.
 */
export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  const { id } = await params;
  return handleOfferRespondPost(request, id, {
    validate: (b) => {
      const r = validateRespondOfferBody(b);
      return r.valid ? null : r.reason;
    },
    runUser: async (correlationId, input) => {
      const client = await createServerClient();
      const full: RespondOfferInput = {
        offerId: input.offerId,
        driverId: input.driverId,
        responseType: input.responseType as RespondOfferInput["responseType"],
        bidAmountCents: input.bidAmountCents,
        idempotencyKey: input.idempotencyKey,
      };
      return respondToOffer(client, full, correlationId);
    },
    runSystem: async (correlationId, input) => {
      const client = createSystemClient();
      const full: RespondOfferInput = {
        offerId: input.offerId,
        driverId: input.driverId,
        responseType: input.responseType as RespondOfferInput["responseType"],
        bidAmountCents: input.bidAmountCents,
        idempotencyKey: input.idempotencyKey,
      };
      return respondToOffer(client, full, correlationId);
    },
  });
}