-- =========================================================================
-- 0031 — helper my_org_memberships() (SECURITY DEFINER)
-- Sessão 19 / ADR-025 D3 (exceção, ver ADR).
--
-- CONTEXTO: resolveLandingPath (lib/auth/landing.ts — login redirect) e o contexto/handler
-- do portal business (getBusinessContext / handleBusinessContext) precisam saber se o caller
-- tem membership de organization e em quais orgs/papéis. Mas organization_memberships NÃO tem
-- SELECT grant a `authenticated` (0015 — metadados de authz sensíveis; "backend resolve
-- server-side"). A RLS `orgm_sel` (0017, `for select to authenticated`) é **moot sem grant**
-- — Policy sem GRANT não deixa a role ler a tabela (mesmo padrão de user_platform_roles,
-- confirmado live na Sessão 18: `permission denied for table user_platform_roles`). Resultado:
-- o ramo business do redirect pós-login falhava com `permission denied` (gap latente deixado
-- pela Sessão 18, documentado inline em landing.ts).
--
-- DECISÃO (alinhada ao ADR-010 Modelo B, espelho de my_platform_role [0030] e my_email
-- [0019]): NÃO abrir SELECT da tabela a `authenticated` (preserva "leitura de authz é
-- sensível"). Função SECURITY DEFINER lê as **próprias rows** (user_id = auth.uid()) e
-- devolve (organization_id, role). Callable via `client.rpc('my_org_memberships')` no client
-- user-scoped. Nenhuma tabela/coluna/enum novo; apenas 1 função + grant execute.
--
-- Diferente de my_platform_role (1:1, PK user_id → retorna text), organization_memberships é
-- N:1 (um usuário pertence a N organizations) → retorna **table(organization_id, role)**
-- (set-returning). O client supabase-js devolve um array de rows (vazio se não autenticado ou
-- sem membership). my_org_ids() (0017) continua sendo usado internamente pelas policies RLS
-- — sem mudança; este helper é para a camada de aplicação ler o próprio papel/tenant.
-- =========================================================================

create or replace function public.my_org_memberships()
returns table(organization_id uuid, role text)
language plpgsql
security definer
set search_path to public, pg_catalog
as $$
declare
  v_caller uuid := auth.uid();
begin
  if v_caller is null then
    return query select null::uuid, null::text where false;
    return;
  end if;
  return query
    select m.organization_id, m.role::text
      from public.organization_memberships m
     where m.user_id = v_caller
     order by m.created_at;
end;
$$;

comment on function public.my_org_memberships() is
  'Memberships de organization do caller (SECURITY DEFINER, Sessão 19 / ADR-025 D3-exceção). Devolve table(organization_id, role) das próprias rows (user_id = auth.uid()) ou vazio. Espelho de my_platform_role (0030) / my_email (0019): organization_memberships sem SELECT grant a authenticated, leitura via RPC DEFINER. Usado por resolveLandingPath (login redirect business) + getBusinessContext + handleBusinessGet (gate 403). Diferente de my_platform_role: N:1 → set-returning.';

grant execute on function public.my_org_memberships() to authenticated, service_role;