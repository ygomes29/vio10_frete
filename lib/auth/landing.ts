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

/**
 * Resolve o papel de plataforma do usuário (super_admin/admin/operator) ou null.
 * Reuso: login (`resolveLandingPath`) + admin handler/context (Sessão 18 / ADR-024
 * D5).
 *
 * Lê via RPC SECURITY DEFINER `my_platform_role()` (migration 0030) — NÃO via select
 * direto em `user_platform_roles`. Motivo: `authenticated` **não tem SELECT grant** na
 * tabela (0015 — metadados de authz sensíveis; "backend resolve server-side"); a RLS
 * `upr_sel` (0017) é moot sem grant (confirmado live: `permission denied for table
 * user_platform_roles`). A RPC DEFINER espelha `my_email()` (0019): lê a própria linha
 * (`user_id = auth.uid()`) sem expor a tabela ao `authenticated`. `userId` é mantido na
 * assinatura por compatibilidade de chamadores (a RPC usa `auth.uid()` internamente).
 *
 * RESOLVIDO (Sessão 19 / ADR-025 D3): `organization_memberships` tem o mesmo padrão
 * (sem SELECT grant a `authenticated` [0015] + RLS `orgm_sel` [0017] moot sem grant).
 * O redirect business em `resolveLandingPath` lê via RPC SECURITY DEFINER
 * `my_org_memberships()` (migration 0031) — espelho de `my_platform_role()`. Espelha
 * `my_email()` (0019): lê as próprias rows (`user_id = auth.uid()`) sem expor a tabela
 * ao `authenticated`. Set-returning (1 user → N orgs).
 */
export async function resolvePlatformRole(
  client: SupabaseClient,
  userId: string,
): Promise<string | null> {
  void userId; // a RPC usa auth.uid() (SECURITY DEFINER); parâmetro mantido p/ compat
  const { data } = await client.rpc("my_platform_role");
  const role = data as string | null;
  return role ?? null;
}

/**
 * Resolve as memberships de organization do caller (business_owner/business_user) ou [].
 * Reuso: login (`resolveLandingPath`) + business handler/context (Sessão 19 / ADR-025
 * D3/D4).
 *
 * Lê via RPC SECURITY DEFINER `my_org_memberships()` (migration 0031) — NÃO via select
 * direto em `organization_memberships`. Motivo: `authenticated` **não tem SELECT grant**
 * na tabela (0015 — metadados de authz sensíveis); a RLS `orgm_sel` (0017) é moot sem
 * grant (confirmado live para o caso análogo `user_platform_roles`). A RPC DEFINER espelha
 * `my_platform_role()` (0030) / `my_email()` (0019): lê as próprias rows
 * (`user_id = auth.uid()`) sem expor a tabela ao `authenticated`. Set-returning
 * (1 user → N orgs). `userId` mantido na assinatura por compatibilidade de chamadores
 * (a RPC usa `auth.uid()` internamente).
 */
export type OrgMembership = { organization_id: string; role: string };

export async function resolveOrgMemberships(
  client: SupabaseClient,
  userId: string,
): Promise<OrgMembership[]> {
  void userId; // a RPC usa auth.uid() (SECURITY DEFINER); parâmetro mantido p/ compat
  const { data } = await client.rpc("my_org_memberships");
  return (data ?? []) as OrgMembership[];
}

export async function resolveLandingPath(client: SupabaseClient): Promise<LandingResult> {
  const { data: { user } } = await client.auth.getUser();
  if (!user) return { error: "unauthenticated" };

  // Plataforma: super_admin/admin/operator → painel operacional.
  const role = await resolvePlatformRole(client, user.id);
  if (role) {
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

  // Business: tem membership → portal empresa. Leitura via RPC SECURITY DEFINER
  // `my_org_memberships()` (0031) — `organization_memberships` sem SELECT grant a
  // `authenticated` (0015); select direto falha com `permission denied` (RLS `orgm_sel`
  // moot sem grant). Sessão 19 / ADR-025 D3.
  const memberships = await resolveOrgMemberships(client, user.id);
  if (memberships.length > 0) {
    return { path: "/business" };
  }

  return { error: "no_role" };
}