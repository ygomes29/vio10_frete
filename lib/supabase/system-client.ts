import "server-only";
import { createClient } from "@supabase/supabase-js";

/**
 * Client Supabase **system-scoped** (ADR-019 D2). Usa `service_role`: bypass de RLS,
 * `auth.uid()` é **null** (contexto system). Guardado por `import "server-only"` —
 * **nunca** importado no client/browser nem exposto ao n8n/DataCrazy/IA (regra mestra,
 * ADR-018 D1). Usado para:
 *  - os 5 RPCs system-only (create_quote, open_dispatch_round, select_winner_and_claim,
 *    confirm_delivery, generate_delivery_otp);
 *  - escrita do idempotency ledger (integration_events/webhook_events — service-only).
 *
 * A autorização do **caller** (n8n) é separada: verify `x-internal-api-key`
 * (`internal-auth.ts`) ANTES de usar este client.
 */
let cached: ReturnType<typeof createClient> | null = null;

export function createSystemClient() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !serviceKey) {
    throw new Error("Supabase env faltando (NEXT_PUBLIC_SUPABASE_URL/SERVICE_ROLE_KEY)");
  }
  // Reutiliza a instância no mesmo processo (dev server) — service_role é imutável.
  if (!cached) {
    cached = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
  }
  return cached;
}