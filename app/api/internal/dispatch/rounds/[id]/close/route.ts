import { handleInternalPost } from "@/lib/api/internal-handler";
import { closeDispatchRound } from "@/lib/services/dispatch";

/**
 * `POST /api/internal/dispatch/rounds/{id}/close` → `select_winner_and_claim`
 * (system-only, ADR-014). Pontua candidatos + chama `claim_delivery` atomicamente
 * (GATE Sessão 10). n8n **não** decide atribuição — só pede o close; o resultado
 * (won/no_candidates/supededed_by_concurrent_claim) vem do SWAC (ACEITAR ≠ GANHAR,
 * ADR-006). Sem vencedor → `no_candidates` → orquestrador abre a próxima rodada.
 */
export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  const { id } = await params;
  return handleInternalPost(request, {
    eventType: "dispatch.close_round",
    source: "internal-api",
    run: (correlationId, body) => {
      const b = (body ?? {}) as { weight_price?: number; weight_distance?: number; max_location_age_seconds?: number };
      return closeDispatchRound(id, {
        weightPrice: b.weight_price,
        weightDistance: b.weight_distance,
        maxLocationAgeSeconds: b.max_location_age_seconds,
      }, correlationId);
    },
  });
}