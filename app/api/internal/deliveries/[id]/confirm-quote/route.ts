import { handleInternalPost } from "@/lib/api/internal-handler";
import { confirmQuote } from "@/lib/services/deliveries";

/**
 * `POST /api/internal/deliveries/{id}/confirm-quote` → `confirm_quote` (user-or-system,
 * ADR-013 D1). Marca a cotação pendente como `confirmed` + `confirmed_at` (transition-first).
 */
export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  const { id } = await params;
  return handleInternalPost(request, {
    eventType: "delivery.confirm_quote",
    source: "internal-api",
    run: (correlationId) => confirmQuote(id, correlationId),
  });
}