import { createServerClient } from "@supabase/ssr";
import type { NextRequest } from "next/server";
import type { NextResponse } from "next/server";

/**
 * Client Supabase **middleware** (ADR-020 D6, ADR-010 D6). Distinto do
 * `server-client.ts` (que usa `cookies()` de `next/headers` com `setAll` no-op
 * em Server Components): o middleware tem runtime próprio e acesso direto aos
 * cookies da requisição/resposta, então NÃO declara `import "server-only"`
 * (que seria injetado pelo compiler do Next em server components).
 *
 * `getAll` lê os cookies da requisição; `setAll` escreve na resposta (refresh
 * de token roda em `getUser()` e propaga os cookies novos ao browser). Sem
 * isto, sessões expiram cedo / logouts aleatórios (doc @supabase/ssr).
 */
export function createMiddlewareClient(
  request: NextRequest,
  response: NextResponse,
) {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !anonKey) {
    throw new Error("Supabase env faltando (NEXT_PUBLIC_SUPABASE_URL/ANON_KEY)");
  }
  return createServerClient(url, anonKey, {
    cookies: {
      getAll() {
        return request.cookies.getAll();
      },
      setAll(toSet: { name: string; value: string; options?: Record<string, unknown> }[]) {
        toSet.forEach(({ name, value, options }) => {
          response.cookies.set(name, value, options as never);
        });
      },
    },
  });
}