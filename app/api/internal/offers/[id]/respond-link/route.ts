import { handleInternalPost } from "@/lib/api/internal-handler";
import { createActionLink } from "@/lib/auth/signed-link";

/**
 * `POST /api/internal/offers/{id}/respond-link` (internal-auth) → gera signed link
 * HMAC (ADR-020 D4). n8n #6 chama e embute a URL na mensagem WhatsApp (ACEITAR/
 * RECUSAR/FAZER LANCE apontam para `POST /api/offers/{id}/respond?token=...`).
 *
 * Geração pura (não muta banco) → não usa idempotency ledger. Reusa
 * `handleInternalPost` só p/ internal-auth + parse; o `run` constrói o link.
 * `NEXT_PUBLIC_APP_URL` (env) é a base pública da URL do link.
 */
export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  const { id: offerId } = await params;
  return handleInternalPost(request, {
    eventType: "offer.respond_link",
    source: "internal-api",
    validate: (b) => {
      if (!b || typeof b !== "object") return "invalid_param";
      const o = b as { driver_id?: unknown; ttl_seconds?: unknown };
      if (typeof o.driver_id !== "string" || !o.driver_id) return "invalid_param";
      if (o.ttl_seconds !== undefined && o.ttl_seconds !== null) {
        if (typeof o.ttl_seconds !== "number" || !Number.isFinite(o.ttl_seconds) || o.ttl_seconds <= 0) {
          return "invalid_param";
        }
      }
      return null;
    },
    run: (_correlationId, body) => {
      const b = body as { driver_id: string; ttl_seconds?: number | null };
      const link = createActionLink({
        offerId,
        driverId: b.driver_id,
        ttlSeconds: b.ttl_seconds ?? undefined,
      });
      const base = process.env.NEXT_PUBLIC_APP_URL ?? "";
      const url = `${base}/api/offers/${offerId}/respond?token=${link.token}`;
      // retorna no shape RpcResult p/ toApiResponse (ok:true → 200)
      return Promise.resolve({
        ok: true,
        reason: null,
        token: link.token,
        url,
        expires_at: link.expiresAt,
      });
    },
  });
}