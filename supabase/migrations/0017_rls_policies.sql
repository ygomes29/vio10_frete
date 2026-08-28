-- 0017_rls_policies.sql
-- RLS policies de VISIBILIDADE (o "V" da matriz ADR-009). Default-deny por padrão;
-- cada tabela expõe só o mínimo. Escrita user-facing continua só via RPCs DEFINER (0016)
-- — authenticated não tem DML em tabelas de domínio (exceto driver_locations, telemetria).
--
-- Princípio: RLS = row visibility (quais linhas o usuário vê). Direito de AGIR (C/E/X/D/R/T)
-- fica na camada de serviço (action authz) + RPCs DEFINER. Defesa em profundidade.
--
-- service_role (system-scoped) faz BYPASSRLS — vê/escreve tudo. anon não tem SELECT grant.
-- Logo estas policies só afetam authenticated (motorista, business, admin, operator).
--
-- Helpers SECURITY DEFINER (rodam como owner, bypassam RLS das tabelas de authz) para
-- resolver, a partir de auth.uid(): é platform admin? qual meu driver_id? quais minhas
-- orgs? posso ver esta corrida? Sem expor user_platform_roles/organization_memberships
-- diretamente ao authenticated (que não tem SELECT nelas).

set search_path = public, pg_catalog;

-- =========================================================================
-- Helpers de autorização (SECURITY DEFINER). EXECUTE concedido a authenticated.
-- =========================================================================
create or replace function public.is_platform_admin()
returns boolean
language sql
security definer
stable
set search_path = public, pg_catalog
as $$
  select exists (
    select 1 from public.user_platform_roles r
    where r.user_id = auth.uid()
      and r.role in ('super_admin','admin','operator')
  );
$$;

create or replace function public.my_driver_id()
returns uuid
language sql
security definer
stable
set search_path = public, pg_catalog
as $$
  select d.id from public.drivers d where d.user_id = auth.uid();
$$;

create or replace function public.my_org_ids()
returns uuid[]
language sql
security definer
stable
set search_path = public, pg_catalog
as $$
  select coalesce(array_agg(m.organization_id), '{}'::uuid[])
  from public.organization_memberships m
  where m.user_id = auth.uid();
$$;

create or replace function public.is_org_member()
returns boolean
language sql
security definer
stable
set search_path = public, pg_catalog
as $$
  select exists (
    select 1 from public.organization_memberships m where m.user_id = auth.uid()
  );
$$;

-- can_view_delivery_request: verdadeiro se o caller (auth.uid) pode VER a corrida:
-- platform admin (tudo) | org da corrida nas suas orgs | driver com assignment ou offer nela.
create or replace function public.can_view_delivery_request(p_id uuid)
returns boolean
language plpgsql
security definer
stable
set search_path = public, pg_catalog
as $$
declare
  v_me uuid := auth.uid();
  v_drv uuid;
  v_org uuid;
begin
  if p_id is null then return false; end if;
  if public.is_platform_admin() then return true; end if;
  -- business: org da corrida nas suas orgs?
  select dr.organization_id into v_org from public.delivery_requests dr where dr.id = p_id;
  if v_org = any(public.my_org_ids()) then return true; end if;
  -- driver: assignment ativa (qualquer status histórico) ou offer dirigida a ele?
  v_drv := public.my_driver_id();
  if v_drv is not null then
    if exists (select 1 from public.delivery_assignments a
               where a.delivery_request_id = p_id and a.driver_id = v_drv)
       or exists (select 1 from public.delivery_offers o
                  where o.delivery_request_id = p_id and o.driver_id = v_drv)
    then
      return true;
    end if;
  end if;
  return false;
end;
$$;

grant execute on function
  public.is_platform_admin(),
  public.my_driver_id(),
  public.my_org_ids(),
  public.is_org_member(),
  public.can_view_delivery_request(uuid)
to authenticated, service_role;

-- =========================================================================
-- profiles: próprio perfil ou platform admin.
-- =========================================================================
drop policy if exists profiles_sel on public.profiles;
create policy profiles_sel on public.profiles
  for select to authenticated
  using (id = auth.uid() or public.is_platform_admin());

-- =========================================================================
-- organizations: platform admin (tudo) ou org nas suas memberships.
-- =========================================================================
drop policy if exists orgs_sel on public.organizations;
create policy orgs_sel on public.organizations
  for select to authenticated
  using (public.is_platform_admin() or id = any(public.my_org_ids()));

-- =========================================================================
-- businesses: platform admin ou org nas suas memberships.
-- =========================================================================
drop policy if exists biz_sel on public.businesses;
create policy biz_sel on public.businesses
  for select to authenticated
  using (public.is_platform_admin() or organization_id = any(public.my_org_ids()));

-- =========================================================================
-- business_locations: via business -> org.
-- =========================================================================
drop policy if exists bizloc_sel on public.business_locations;
create policy bizloc_sel on public.business_locations
  for select to authenticated
  using (
    public.is_platform_admin()
    or exists (
      select 1 from public.businesses b
      where b.id = business_locations.business_id
        and b.organization_id = any(public.my_org_ids())
    )
  );

-- =========================================================================
-- user_platform_roles / organization_memberships: metadados de authz.
-- authenticated não tem SELECT grant (0015), mas por defesa em profundidade:
-- vê só a própria linha (e platform admin vê tudo).
-- =========================================================================
drop policy if exists upr_sel on public.user_platform_roles;
create policy upr_sel on public.user_platform_roles
  for select to authenticated
  using (user_id = auth.uid() or public.is_platform_admin());

drop policy if exists orgm_sel on public.organization_memberships;
create policy orgm_sel on public.organization_memberships
  for select to authenticated
  using (public.is_platform_admin() or user_id = auth.uid() or organization_id = any(public.my_org_ids()));

-- =========================================================================
-- drivers: platform-scoped (sem organization_id).
--  - platform admin: vê todos.
--  - driver: vê a própria linha.
--  - business_* (is_org_member): vê drivers ativos do tenant (MVP single-tenant;
--    multi-tenant adiado — ADR-009 "Fora do escopo"). Necessário para despacho manual.
-- =========================================================================
drop policy if exists drivers_sel on public.drivers;
create policy drivers_sel on public.drivers
  for select to authenticated
  using (
    public.is_platform_admin()
    or user_id = auth.uid()
    or public.is_org_member()
  );

-- =========================================================================
-- vehicles / driver_availability / driver_locations: dono do driver, platform admin,
-- ou business (org member) para despacho. driver_locations também é gravável pelo dono.
-- =========================================================================
drop policy if exists vehicles_sel on public.vehicles;
create policy vehicles_sel on public.vehicles
  for select to authenticated
  using (public.is_platform_admin() or driver_id = public.my_driver_id() or public.is_org_member());

drop policy if exists driver_avail_sel on public.driver_availability;
create policy driver_avail_sel on public.driver_availability
  for select to authenticated
  using (public.is_platform_admin() or driver_id = public.my_driver_id() or public.is_org_member());

drop policy if exists driver_loc_sel on public.driver_locations;
create policy driver_loc_sel on public.driver_locations
  for select to authenticated
  using (public.is_platform_admin() or driver_id = public.my_driver_id() or public.is_org_member());

-- driver_locations: única mutação direta do authenticated (telemetria). Só o próprio driver.
drop policy if exists driver_loc_ins on public.driver_locations;
create policy driver_loc_ins on public.driver_locations
  for insert to authenticated
  with check (driver_id = public.my_driver_id());

drop policy if exists driver_loc_upd on public.driver_locations;
create policy driver_loc_upd on public.driver_locations
  for update to authenticated
  using (driver_id = public.my_driver_id())
  with check (driver_id = public.my_driver_id());

-- =========================================================================
-- driver_documents: sensível (documentos pessoais). Só platform admin + próprio driver.
-- (business_* não veem documentos de motoristas — tightening vs. matriz DRV genérica;
--  despacho só precisa de identidade/disponibilidade, não de CNH.)
-- =========================================================================
drop policy if exists driver_docs_sel on public.driver_documents;
create policy driver_docs_sel on public.driver_documents
  for select to authenticated
  using (public.is_platform_admin() or driver_id = public.my_driver_id());

-- =========================================================================
-- delivery_requests: núcleo. Visibilidade via can_view_delivery_request().
-- =========================================================================
drop policy if exists delreq_sel on public.delivery_requests;
create policy delreq_sel on public.delivery_requests
  for select to authenticated
  using (public.can_view_delivery_request(id));

-- =========================================================================
-- Tabelas filhas de corrida: visibilidade = pode ver a delivery_request pai.
-- =========================================================================
drop policy if exists delitems_sel on public.delivery_items;
create policy delitems_sel on public.delivery_items
  for select to authenticated
  using (public.can_view_delivery_request(delivery_request_id));

drop policy if exists delquotes_sel on public.delivery_quotes;
create policy delquotes_sel on public.delivery_quotes
  for select to authenticated
  using (public.can_view_delivery_request(delivery_request_id));

drop policy if exists rounds_sel on public.dispatch_rounds;
create policy rounds_sel on public.dispatch_rounds
  for select to authenticated
  using (public.can_view_delivery_request(delivery_request_id));

drop policy if exists offers_sel on public.delivery_offers;
create policy offers_sel on public.delivery_offers
  for select to authenticated
  using (public.can_view_delivery_request(delivery_request_id));

drop policy if exists bids_sel on public.bids;
create policy bids_sel on public.bids
  for select to authenticated
  using (public.can_view_delivery_request(delivery_request_id));

drop policy if exists assigns_sel on public.delivery_assignments;
create policy assigns_sel on public.delivery_assignments
  for select to authenticated
  using (public.can_view_delivery_request(delivery_request_id));

drop policy if exists events_sel on public.delivery_events;
create policy events_sel on public.delivery_events
  for select to authenticated
  using (public.can_view_delivery_request(delivery_request_id));

drop policy if exists pod_sel on public.proof_of_delivery;
create policy pod_sel on public.proof_of_delivery
  for select to authenticated
  using (public.can_view_delivery_request(delivery_request_id));

-- =========================================================================
-- pricing_rules: platform admin (tudo) | regra global (organization_id null) | regra
-- de uma das suas orgs.
-- =========================================================================
drop policy if exists pricing_sel on public.pricing_rules;
create policy pricing_sel on public.pricing_rules
  for select to authenticated
  using (
    public.is_platform_admin()
    or organization_id is null
    or organization_id = any(public.my_org_ids())
  );

-- =========================================================================
-- service_areas: config operacional (Congonhas). Visível a qualquer authenticated
-- com papel (admin, org member ou driver). Não é segredo por tenant no MVP.
-- =========================================================================
drop policy if exists svcareas_sel on public.service_areas;
create policy svcareas_sel on public.service_areas
  for select to authenticated
  using (public.is_platform_admin() or public.is_org_member() or public.my_driver_id() is not null);

-- =========================================================================
-- notifications: destinatário (user ou driver) ou platform admin.
-- =========================================================================
drop policy if exists notif_sel on public.notifications;
create policy notif_sel on public.notifications
  for select to authenticated
  using (
    public.is_platform_admin()
    or recipient_user_id = auth.uid()
    or recipient_driver_id = public.my_driver_id()
  );

-- =========================================================================
-- webhook_events / integration_events: SISTEMA apenas. authenticated não tem SELECT
-- grant (0015) e RLS está default-deny (nenhuma policy). service_role faz bypass.
-- Nada a declarar aqui — explicitado para clareza.
-- =========================================================================
-- (intencionalmente sem policy de SELECT para authenticated: default-deny)

-- =========================================================================
-- Registro da postura.
-- =========================================================================
comment on schema public is
  'ViO10: schema de dominio. RLS default-deny com policies least-privilege (0017, ADR-009): visibilidade por org/driver/admin; mutacao user-facing so via RPC DEFINER (0016); service_role bypass; anon sem grant. Escrever e ler diretos em tabelas de dominio pelo authenticated nao sao permitidos (exceto driver_locations).';