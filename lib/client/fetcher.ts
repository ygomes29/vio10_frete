"use client";

/**
 * Fetch helper client-side (ADR-023 Fase 4). Same-origin → cookies enviados
 * automaticamente (`credentials: same-origin` default). Sem client Supabase no
 * browser: toda leitura/mutação passa por Route Handlers (cookie JWT → RLS).
 * Regra mestra: o frontend só apresenta estado oficial e coleta ações.
 */

export type ApiResult<T = Record<string, unknown>> = {
  ok: boolean;
  reason: string | null;
  data?: T;
};

/** GET same-origin. */
export async function apiGet<T = Record<string, unknown>>(path: string): Promise<ApiResult<T>> {
  try {
    const res = await fetch(path, {
      method: "GET",
      headers: { "x-correlation-id": crypto.randomUUID() },
      cache: "no-store",
    });
    const body = (await res.json().catch(() => ({}))) as T & { ok?: boolean; reason?: string };
    return { ok: Boolean(body.ok), reason: body.reason ?? null, data: body };
  } catch {
    return { ok: false, reason: "network_error" };
  }
}

/** POST same-origin com JSON. Retorna `{ok, reason, data, status}`. */
export async function apiPost<T = Record<string, unknown>>(
  path: string,
  payload: unknown,
  opts: { idempotencyKey?: string } = {},
): Promise<ApiResult<T> & { status?: number }> {
  try {
    const headers: Record<string, string> = {
      "Content-Type": "application/json",
      "x-correlation-id": crypto.randomUUID(),
    };
    if (opts.idempotencyKey) headers["idempotency-key"] = opts.idempotencyKey;
    const res = await fetch(path, {
      method: "POST",
      headers,
      body: JSON.stringify(payload ?? {}),
      cache: "no-store",
    });
    const body = (await res.json().catch(() => ({}))) as T & { ok?: boolean; reason?: string };
    return { ok: Boolean(body.ok), reason: body.reason ?? null, data: body, status: res.status };
  } catch {
    return { ok: false, reason: "network_error" };
  }
}