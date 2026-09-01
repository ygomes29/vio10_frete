import "server-only";
import type { SupabaseClient } from "@supabase/supabase-js";

/**
 * Resolve a rota de destino após login (ADR-023 Fase 2 / D3). O frontend só
 * apresenta; o papel vem do backend (RLS deixa o usuário ler as próprias rows
 * de `user_platform_roles`, `drivers`, `organization_memberships` — 0017).
 *
 * Prioridade: plataforma (admin/operator) → /admin; driver → /driver;
 * business → /business; nenhum → null (login recusa).
 *
 * Retorna `{ path }` ou `{ error }` — puro p/ teste; a Server Action consome.
 */
export type LandingResult = { path: string } | { error: string };

export async function resolveLandingPath(client: SupabaseClient): Promise<LandingResult> {
  const { data: { user } } = await client.auth.getUser();
  if (!user) return { error: "unauthenticated" };

  // Plataforma: super_admin/admin/operator → painel operacional.
  const { data: roleRow } = await client
    .from("user_platform_roles")
    .select("role")
    .eq("user_id", user.id)
    .maybeSingle();
  if (roleRow && (roleRow as { role: string }).role) {
    return { path: "/admin" };
  }

  // Driver: tem row em drivers → PWA entregador.
  const { data: driverRow } = await client
    .from("drivers")
    .select("id")
    .eq("user_id", user.id)
    .maybeSingle();
  if (driverRow && (driverRow as { id: string }).id) {
    return { path: "/driver" };
  }

  // Business: tem membership → portal empresa.
  const { data: memberRow } = await client
    .from("organization_memberships")
    .select("id")
    .eq("user_id", user.id)
    .limit(1)
    .maybeSingle();
  if (memberRow && (memberRow as { id: string }).id) {
    return { path: "/business" };
  }

  return { error: "no_role" };
}