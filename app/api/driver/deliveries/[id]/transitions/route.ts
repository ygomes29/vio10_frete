import { handleUserPost } from "@/lib/api/user-handler";
import {
  validateTransitionBody,
  transitionDeliveryDriver,
  type TransitionDriverInput,
} from "@/lib/services/driver";

/**
 * `POST /api/driver/deliveries/{id}/transitions` → `transition_delivery`
 * (driver path, ADR-016 D1). Cookie JWT (user-scoped); a RPC resolve o ator de
 * `auth.uid()` (driver c/ assignment ativa). Driver só as 4 transições pós-`assigned`:
 * `driver_to_pickup`, `at_pickup`, `picked_up`, `in_transit`. Não pode
 * `delivered`/`cancelled`/`failed`.
 */
export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  const { id } = await params;
  return handleUserPost(request, {
    eventType: "driver.transition",
    validate: (b) => {
      const r = validateTransitionBody(b);
      return r.valid ? null : r.reason;
    },
    run: async (correlationId, body, ctx) => {
      const b = body as { to_status: TransitionDriverInput["toStatus"]; metadata?: Record<string, unknown> | null };
      return transitionDeliveryDriver(
        ctx.client,
        id,
        { toStatus: b.to_status, metadata: b.metadata ?? null },
        correlationId,
      );
    },
  });
}