import { handleInternalPost } from "@/lib/api/internal-handler";
import { transitionDeliverySystem } from "@/lib/services/deliveries";

/**
 * `POST /api/internal/deliveries/{id}/transitions` → `transition_delivery` com
 * `actor_type='system'` (matriz ator×transição ADR-016 D1). Path **system**; o path
 * driver/user (via JWT + signed links) é a Sessão 15. Body: `{ to_status, metadata? }`.
 */
export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  const { id } = await params;
  return handleInternalPost(request, {
    eventType: "delivery.transition",
    source: "internal-api",
    validate: (b) => {
      if (!b || typeof b !== "object") return "invalid_param";
      const bo = b as { to_status?: unknown };
      if (typeof bo.to_status !== "string" || !bo.to_status) return "invalid_param";
      return null;
    },
    run: (correlationId, body) => {
      const b = body as { to_status: string; metadata?: Record<string, unknown> | null };
      return transitionDeliverySystem(id, { toStatus: b.to_status, metadata: b.metadata }, correlationId);
    },
  });
}