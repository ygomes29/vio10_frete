import { handleInternalPost } from "@/lib/api/internal-handler";
import {
  validateDispatchRoundBody,
  openDispatchRound,
  type OpenDispatchInput,
} from "@/lib/services/dispatch";

/**
 * `POST /api/internal/deliveries/{id}/dispatch/rounds` → `open_dispatch_round`
 * (system-only, ADR-013 D2). Abre **uma** rodada por chamada (`round_already_open`
 * guarda sobreposição). O loop de raio progressivo é do n8n (ADR-018 D4) — esta rota
 * só abre a próxima rodada quando solicitada.
 */
export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  const { id } = await params;
  return handleInternalPost(request, {
    eventType: "dispatch.open_round",
    source: "internal-api",
    validate: (b) => {
      const r = validateDispatchRoundBody(b);
      return r.valid ? null : r.reason;
    },
    run: (correlationId, body) =>
      openDispatchRound({ ...(body as Partial<OpenDispatchInput>), delivery_request_id: id } as OpenDispatchInput, correlationId),
  });
}