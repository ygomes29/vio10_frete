import "server-only";
import { timingSafeEqual } from "node:crypto";

/**
 * Autorização de system-callers (n8n) — ADR-019 D3. n8n **não** recebe `service_role`
 * (nunca vaza, regra mestra). Ele envia um shared secret (`x-internal-api-key`) que o
 * Route Handler verifica em tempo constante; em caso positivo, o handler usa
 * `createSystemClient()` server-side.
 *
 * MVP: shared secret via env `INTERNAL_API_KEY`. mTLS/IP-allowlist + rotação → Sessão 22/26.
 */
export function verifyInternalApiKey(headerValue: string | null): boolean {
  const expected = process.env.INTERNAL_API_KEY;
  if (!expected) {
    // Sem secret configurado → recusar tudo (fail-closed). Nunca deixar system endpoints
    // abertos por ausência de config.
    return false;
  }
  if (!headerValue) return false;
  const a = Buffer.from(headerValue);
  const b = Buffer.from(expected);
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}

/** Helper: extrai o header do Request (case-insensitive na prática via Headers). */
export function getInternalApiKey(request: Request): string | null {
  return request.headers.get("x-internal-api-key");
}