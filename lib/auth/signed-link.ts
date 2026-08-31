import "server-only";
import { createHmac, timingSafeEqual } from "node:crypto";

/**
 * Signed action links (ADR-020 D3) — links de ação do fluxo WhatsApp (DataCrazy),
 * workflow n8n #6 → #7. O entregador responde a uma oferta (ACEITAR/RECUSAR/
 * FAZER LANCE) por um link que **autentica sem login**: o token prova a identidade
 * do driver + escopia a (offer, driver) + expira.
 *
 * Constraints (docs/SECURITY.md §423-428, docs/DATACRAZY_INTEGRATION.md):
 * - Assinado (HMAC) e **expirável**.
 * - Escopo limitado à offer/driver específicos (IDOR-protegido).
 * - Replay/forja → rejeitado (a idempotência interna de `respond_to_offer` garante
 *   uma resposta válida por (offer,driver); `exp` rejeita tokens vencidos).
 *
 * Formato: `base64url(payload) + "." + base64url(hmac_sha256(payload))`.
 * Payload: `{ o: offerId, d: driverId, e: expEpochSec, n: nonce }`.
 * Secret: env `ACTION_LINK_SIGNING_SECRET` (fail-closed se ausente). Nunca logar.
 *
 * Decisão (AskUserQuestion): token HMAC system-scoped — o handler verifica o token e
 * chama `respond_to_offer` system-scoped (`auth.uid()` null, `p_driver_id` do token).
 * O binding (offer,driver)+expiração **é** a autorização (não minta JWT real).
 */

const DEFAULT_TTL_SECONDS = 900; // alinhado à janela da rodada (n8n #5 response_window)

type Payload = {
  o: string; // offer id
  d: string; // driver id
  e: number; // exp epoch (segundos)
  n: string; // nonce (anti-replay de geração)
};

function getSecret(): string {
  const secret = process.env.ACTION_LINK_SIGNING_SECRET;
  if (!secret) {
    // fail-closed: sem secret → não gera nem verifica links. Nunca deixar links
    // forjáveis por ausência de config.
    throw new Error("ACTION_LINK_SIGNING_SECRET não configurado (fail-closed)");
  }
  return secret;
}

/** base64url sem padding (URL-safe p/ query string). */
function b64url(input: Buffer | string): string {
  const buf = typeof input === "string" ? Buffer.from(input, "utf8") : input;
  return buf.toString("base64url");
}

function b64urlDecode(s: string): Buffer {
  return Buffer.from(s, "base64url");
}

function sign(payloadB64: string, secret: string): string {
  return b64url(createHmac("sha256", secret).update(payloadB64).digest());
}

export type ActionLink = {
  token: string;
  expiresAt: string; // ISO 8601
};

/**
 * Gera um signed link para o driver responder à oferta. Chamado pelo endpoint
 * system `POST /api/internal/offers/{id}/respond-link` (n8n #6 embute na mensagem).
 */
export function createActionLink(opts: {
  offerId: string;
  driverId: string;
  ttlSeconds?: number;
}): ActionLink {
  if (!opts.offerId || !opts.driverId) {
    throw new Error("createActionLink: offerId e driverId obrigatórios");
  }
  const ttl = opts.ttlSeconds ?? DEFAULT_TTL_SECONDS;
  const exp = Math.floor(Date.now() / 1000) + ttl;
  const payload: Payload = {
    o: opts.offerId,
    d: opts.driverId,
    e: exp,
    n: crypto.randomUUID(),
  };
  const payloadB64 = b64url(JSON.stringify(payload));
  const sig = sign(payloadB64, getSecret());
  return {
    token: `${payloadB64}.${sig}`,
    expiresAt: new Date(exp * 1000).toISOString(),
  };
}

export type VerifiedLink = {
  offerId: string;
  driverId: string;
  exp: number;
};

/**
 * Verifica um signed link. Retorna `{offerId, driverId, exp}` ou `null` se
 * inválido (HMAC não bate, expirado, malformado, secret ausente). Se
 * `expectedOfferId` for passado, exige que `o` no token bata (proteção IDOR: o
 * token de uma offer não serve para outra).
 */
export function verifyActionLink(
  token: string,
  expectedOfferId?: string,
): VerifiedLink | null {
  if (!token) return null;
  let secret: string;
  try {
    secret = getSecret();
  } catch {
    return null; // fail-closed
  }
  const parts = token.split(".");
  if (parts.length !== 2) return null;
  const [payloadB64, sig] = parts;
  const expectedSig = sign(payloadB64, secret);
  // timing-safe compare da assinatura.
  const a = b64urlDecode(sig);
  const b = b64urlDecode(expectedSig);
  if (a.length !== b.length || !timingSafeEqual(a, b)) return null;

  let payload: Payload;
  try {
    payload = JSON.parse(b64urlDecode(payloadB64).toString("utf8")) as Payload;
  } catch {
    return null;
  }
  if (
    typeof payload.o !== "string" || typeof payload.d !== "string" ||
    typeof payload.e !== "number" || typeof payload.n !== "string"
  ) {
    return null;
  }
  // expiração (segundos)
  if (Math.floor(Date.now() / 1000) >= payload.e) return null;
  // escopo IDOR: token deve casar com a offer do path
  if (expectedOfferId && payload.o !== expectedOfferId) return null;
  return { offerId: payload.o, driverId: payload.d, exp: payload.e };
}

/** TTL default exposto p/ documentação/validação. */
export const DEFAULT_ACTION_LINK_TTL = DEFAULT_TTL_SECONDS;