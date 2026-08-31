import { NextResponse, type NextRequest } from "next/server";
import { createMiddlewareClient } from "@/lib/supabase/middleware-client";

/**
 * Middleware — refresh de sessão + proteção de route groups (ADR-020 D6,
 * ADR-010 D6). Roda server-side antes de qualquer render.
 *
 *   1. `getUser()` refresca o JWT se preciso; os cookies atualizados são
 *      escritos na `response` via `setAll` (middleware-client) → browser.
 *   2. Paths sob `/driver`, `/admin`, `/business` exigem sessão; sem cookie →
 *      307 para `/auth/login` (NextResponse.redirect default; validado live Sessão 15).
 *   3. `/api/*` (Route Handlers fazem auth própria — internal-auth p/ system,
 *      cookie/JWT p/ user), `/auth/*` (login) e estáticos são liberados pelo
 *      matcher — o middleware nem roda neles.
 */
export async function middleware(request: NextRequest): Promise<NextResponse> {
  const response = NextResponse.next({ request: { headers: request.headers } });
  const supabase = createMiddlewareClient(request, response);
  // getUser() dispara o refresh se o access token expirou; setAll grava na resposta.
  await supabase.auth.getUser();

  const path = request.nextUrl.pathname;
  const isProtected = /^(\/driver|\/admin|\/business)(\/|$)/.test(path);
  if (isProtected) {
    const { data: { user } } = await supabase.auth.getUser();
    if (!user) {
      const redirectUrl = request.nextUrl.clone();
      redirectUrl.pathname = "/auth/login";
      redirectUrl.searchParams.set("redirect", path);
      return NextResponse.redirect(redirectUrl);
    }
  }
  return response;
}

// Roda em tudo exceto estáticos, /api/* (auth própria nos handlers) e /auth/*.
export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico|api/|auth/).*)"],
};