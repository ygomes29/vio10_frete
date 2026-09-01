import "server-only";
import { createServerClient } from "@/lib/supabase/server-client";
import { resolveOrgMemberships, type OrgMembership } from "@/lib/auth/landing";
import type { SupabaseClient } from "@supabase/supabase-js";

export type { OrgMembership };
export type BusinessContext = {
  client: SupabaseClient;
  memberships: OrgMembership[];
};

/**
 * Contexto business server-side (Sessão 19 / ADR-025 D4). Usado por Server Components
 * sob `(business)`. Middleware já exige sessão em `/business` (307 login); aqui
 * confirmamos sessão + que o user tem ≥1 membership de organization (via RPC SECURITY
 * DEFINER `my_org_memberships()` — 0031; `organization_memberships` sem SELECT grant a
 * `authenticated`, RLS `orgm_sel` moot). RLS (`can_view_delivery_request`/`my_org_ids()`)
 * escopa as leituras ao tenant automaticamente. Retorna `{client, memberships}` ou null
 * (não auth / sem membership) — a página decide (redirect ou mensagem). Espelho de
 * `getAdminContext()` (Sessão 18), mas set-returning (1 user → N orgs).
 */
export async function getBusinessContext(): Promise<BusinessContext | null> {
  const client = await createServerClient();
  const { data: { user } } = await client.auth.getUser();
  if (!user) return null;
  const memberships = await resolveOrgMemberships(client, user.id);
  if (memberships.length === 0) return null;
  return { client, memberships };
}