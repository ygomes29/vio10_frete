-- =========================================================================
-- 0030 — helper my_platform_role() (SECURITY DEFINER)
-- Sessão 18 / ADR-024 D6 (exceção, ver ADR).
--
-- CONTEXTO: resolvePlatformRole (lib/auth/landing.ts — reuso por resolveLandingPath
-- [login redirect] + getAdminContext + handleAdminGet) lê o papel do caller via client
-- **user-scoped** (cookie JWT). Mas user_platform_roles NÃO tem SELECT grant a
-- `authenticated` (0015 — metadados de authz sensíveis; "backend resolve server-side").
-- A RLS `upr_sel` (0017, `for select to authenticated`) é **moot sem grant** — Policy
-- sem GRANT não deixa a role ler a tabela (confirmado live: `permission denied for
-- table user_platform_roles`). Resultado: admin autenticado → resolvePlatformRole = null
-- → 403 em /api/admin/* e redirect ao /driver no login (mascarado desde a Sessão 17
-- porque só drivers foram testados live — driver SEM role → null → /driver é o caminho
-- correto, então o bug do admin nunca apareceu).
--
-- DECISÃO (alinhada ao ADR-010 Modelo B): NÃO abrir SELECT da tabela a `authenticated`
-- (preserva "leitura de papel é sensível"). Espelho de `my_email()` (0019): função
-- SECURITY DEFINER lê a **própria linha** (user_id = auth.uid()) e devolve o role text.
-- Callable via `client.rpc('my_platform_role')` no client user-scoped. Nenhuma tabela/
-- coluna/enum novo; apenas 1 função + grant execute.
--
-- user_platform_roles.user_id é PRIMARY KEY (0004) → exatamente 1 role por usuário.
-- =========================================================================

create or replace function public.my_platform_role()
returns text
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_caller uuid := auth.uid();
  v_role   text;
begin
  if v_caller is null then
    return null;
  end if;
  select r.role::text
    into v_role
    from public.user_platform_roles r
   where r.user_id = v_caller;
  return v_role;
end;
$$;

comment on function public.my_platform_role() is
  'Papel platform do caller (SECURITY DEFINER, Sessão 18 / ADR-024 D6-exceção). Devolve o role text da própria linha (user_id = auth.uid()) ou null. Espelho de my_email() (0019): user_platform_roles sem SELECT grant a authenticated, leitura via RPC DEFINER. Usado por resolvePlatformRole (login redirect + admin gate 403).';

grant execute on function public.my_platform_role() to authenticated, service_role;