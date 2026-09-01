import "server-only";
import { createServerClient } from "@/lib/supabase/server-client";
import { resolvePlatformRole } from "@/lib/auth/landing";
import type { SupabaseClient } from "@supabase/supabase-js";

export type AdminContext = { client: SupabaseClient; role: string };

/**
 * Contexto admin server-side (Sessão 18 / ADR-024 D5). Usado por Server Components
 * sob `(admin)`. Middleware já exige sessão em /admin (307 login); aqui confirmamos
 * sessão + que o user tem role de plataforma (super_admin/admin/operator — RLS
 * `is_platform_admin()` aplica cross-tenant nas leituras). Retorna `{client, role}`
 * ou null (não auth / não admin) — a página decide (redirect ou mensagem).
 */
export async function getAdminContext(): Promise<AdminContext | null> {
  const client = await createServerClient();
  const { data: { user } } = await client.auth.getUser();
  if (!user) return null;
  const role = await resolvePlatformRole(client, user.id);
  if (!role) return null;
  return { client, role };
}