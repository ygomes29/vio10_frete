import "server-only";
import { createHmac, timingSafeEqual } from "node:crypto";

/**
 * Verificação de signature de webhooks DataCrazy inbound (ADR-020 D5, SECURITY §454).
 * HMAC-SHA256 do **raw body** c/ `DATACRAZY_WEBHOOK_SECRET`, comparada em tempo constante
 * contra o header `x-datacrazy-signature` (hex). **Fail-closed**: sem secret → recusa tudo.
 *
 * DataCrazy/IA nunca escreve no banco; o webhook chama Route Handlers (regra mestra).
 * MVP: shared secret. mTLS/rotação → Sessão 22/26.
 */
export function verifyDatacrazySignature(rawBody: string, signatureHeader: string | null): boolean {
  const secret = process.env.DATACRAZY_WEBHOOK_SECRET;
  if (!secret) return false; // fail-closed
  if (!signatureHeader) return false;
  const expected = createHmac("sha256", secret).update(rawBody).digest("hex");
  const a = Buffer.from(signatureHeader);
  const b = Buffer.from(expected);
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}

/** Helper: extrai o header de signature. */
export function getDatacrazySignature(request: Request): string | null {
  return request.headers.get("x-datacrazy-signature");
}