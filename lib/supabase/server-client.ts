import "server-only";
import { cookies } from "next/headers";
import { createServerClient as createSSRClient } from "@supabase/ssr";

/**
 * Client Supabase **user-scoped** (ADR-019 D2). Lê o JWT do cookie da requisição
 * (ADR-010 D5/D6: cookie-based, JWT DB-lookup, sem custom claims). RLS aplica;
 * `auth.uid()` é o usuário autenticado. Usado para operações de usuário/driver.
 *
 * Para operações system-only (os 5 RPCs) e escrita do idempotency ledger, use
 * `createSystemClient()` — nunca este client.
 */
export async function createServerClient() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !anonKey) {
    throw new Error("Supabase env faltando (NEXT_PUBLIC_SUPABASE_URL/ANON_KEY)");
  }
  const store = await cookies();
  return createSSRClient(url, anonKey, {
    cookies: {
      getAll() {
        return store.getAll();
      },
      setAll(toSet: { name: string; value: string; options?: Record<string, unknown> }[]) {
        // Em Route Handlers, setar cookies exige manipular a Response. Para reads
        // (getUser) basta getAll. Refresh de cookie na borda fica com a Sessão 15/17
        // (middleware + Response). Por ora, no-op seguro em server components.
        try {
          toSet.forEach(({ name, value, options }) => store.set(name, value, options as never));
        } catch {
          // chamado dentro de Server Component onde cookies é read-only — ignorar
        }
      },
    },
  });
}