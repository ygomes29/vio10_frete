-- 0020_management_rpcs.sql
-- Sessão 06 (ADR-011): gestão de empresas (organizations/businesses/business_locations),
-- veículos e status do entregador. RPCs SECURITY DEFINER (Modelo B, Sessão 04):
-- authenticated sem DML de domínio; mutação só via RPC + checagem interna de auth.uid().
-- Nenhuma tabela nova. Único schema change: índice unique em vehicles(plate).

set search_path = public, pg_catalog;

-- ============================================================================
-- Unique constraint: vehicles.plate (placa fisicamente única). Idempotência do
-- create_vehicle via on conflict (plate). Adicionado aqui (não existia em 0005).
-- ============================================================================
create unique index if not exists idx_vehicles_plate_uk on public.vehicles(plate);

-- ============================================================================
-- create_organization(p_name, p_legal_name, p_document)
-- Provisionamento de tenant. super_admin/admin ou system. Sem chave natural (nomes
-- podem repetir); dedup é responsabilidade do serviço.
-- ============================================================================
create or replace function public.create_organization(
  p_name       text,
  p_legal_name text,
  p_document   text
) returns table(ok boolean, reason text, organization_id uuid)
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_caller uuid := auth.uid();
  v_id     uuid;
begin
  if v_caller is not null and not public.is_super_or_admin() then
    return query select false, 'not_authorized', null::uuid; return;
  end if;

  if p_name is null or p_name = '' then
    return query select false, 'invalid_meta', null::uuid; return;
  end if;

  insert into public.organizations(name, legal_name, document)
  values (p_name, p_legal_name, p_document)
  returning id into v_id;

  return query select true, 'created', v_id;
end;
$$;

comment on function public.create_organization(text,text,text) is
  'Cria organização (tenant). SECURITY DEFINER, ADR-011 D4. super_admin/admin ou system.';

-- ============================================================================
-- create_business(p_organization_id, p_name)
-- super_admin/admin OU business_owner da própria org. Valida org existe.
-- ============================================================================
create or replace function public.create_business(
  p_organization_id uuid,
  p_name           text
) returns table(ok boolean, reason text, business_id uuid)
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_caller uuid := auth.uid();
  v_id     uuid;
begin
  if v_caller is not null then
    if not public.is_super_or_admin()
       and not exists (
         select 1 from public.organization_memberships m
         where m.user_id = v_caller
           and m.organization_id = p_organization_id
           and m.role = 'business_owner'
       ) then
      return query select false, 'not_authorized', null::uuid; return;
    end if;
  end if;

  if p_name is null or p_name = '' then
    return query select false, 'invalid_meta', null::uuid; return;
  end if;

  if not exists (select 1 from public.organizations where id = p_organization_id) then
    return query select false, 'org_not_found', null::uuid; return;
  end if;

  insert into public.businesses(organization_id, name)
  values (p_organization_id, p_name)
  returning id into v_id;

  return query select true, 'created', v_id;
end;
$$;

comment on function public.create_business(uuid,text) is
  'Cria business (marca) dentro de uma org. SECURITY DEFINER, ADR-011 D4. super/admin ou business_owner da própria org.';

-- ============================================================================
-- create_business_location(p_business_id, p_label, p_address, p_latitude,
--   p_longitude, p_contact_name, p_contact_phone)
-- business_owner da org do business OU super/admin. Monta point (PostGIS) se
-- lat/lng ambos presentes; respeita o CHECK "ambos null ou ambos set" do schema.
-- ============================================================================
create or replace function public.create_business_location(
  p_business_id    uuid,
  p_label          text,
  p_address        text,
  p_latitude       double precision,
  p_longitude      double precision,
  p_contact_name   text,
  p_contact_phone  text
) returns table(ok boolean, reason text, business_location_id uuid)
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $$
declare
  v_caller uuid := auth.uid();
  v_org_id  uuid;
  v_id      uuid;
  v_point   geography(Point,4326);
begin
  -- resolve org do business (e valida existência)
  select organization_id into v_org_id from public.businesses where id = p_business_id;
  if not found then
    return query select false, 'business_not_found', null::uuid; return;
  end if;

  if v_caller is not null then
    if not public.is_super_or_admin()
       and not exists (
         select 1 from public.organization_memberships m
         where m.user_id = v_caller
           and m.organization_id = v_org_id
           and m.role = 'business_owner'
       ) then
      return query select false, 'not_authorized', null::uuid; return;
    end if;
  end if;

  if p_address is null or p_address = '' then
    return query select false, 'invalid_meta', null::uuid; return;
  end if;

  -- lat/lng: ambos null OU ambos set (CHECK do schema). parcial -> invalid.
  if (p_latitude is null) <> (p_longitude is null) then
    return query select false, 'invalid_latlng', null::uuid; return;
  end if;

  if p_latitude is not null and p_longitude is not null then
    v_point := st_setsrid(st_makepoint(p_longitude, p_latitude), 4326)::geography(Point,4326);
  end if;

  insert into public.business_locations(
    business_id, label, address, latitude, longitude, point,
    contact_name, contact_phone)
  values (p_business_id, p_label, p_address, p_latitude, p_longitude, v_point,
          p_contact_name, p_contact_phone)
  returning id into v_id;

  return query select true, 'created', v_id;
end;
$$;

comment on function public.create_business_location(uuid,text,text,double precision,double precision,text,text) is
  'Cria unidade física (business_location). SECURITY DEFINER, ADR-011 D4. business_owner da org ou super/admin. Monta point via PostGIS.';

-- ============================================================================
-- create_vehicle(p_driver_id, p_vehicle_type, p_plate, p_model, p_capacity_kg)
-- driver self (drivers.user_id=auth.uid de p_driver_id) OU super/admin OU system.
-- Idempotente via unique(plate): on conflict do nothing -> already_exists.
-- ============================================================================
create or replace function public.create_vehicle(
  p_driver_id    uuid,
  p_vehicle_type public.vehicle_type,
  p_plate        text,
  p_model        text,
  p_capacity_kg  integer
) returns table(ok boolean, reason text, vehicle_id uuid)
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_caller uuid := auth.uid();
  v_id     uuid;
begin
  if v_caller is not null then
    if not public.is_super_or_admin()
       and not exists (
         select 1 from public.drivers d
         where d.id = p_driver_id and d.user_id = v_caller
       ) then
      return query select false, 'not_authorized', null::uuid; return;
    end if;
  end if;

  if p_plate is null or p_plate = '' then
    return query select false, 'invalid_meta', null::uuid; return;
  end if;

  if not exists (select 1 from public.drivers where id = p_driver_id) then
    return query select false, 'driver_not_found', null::uuid; return;
  end if;

  if p_capacity_kg is not null and p_capacity_kg <= 0 then
    return query select false, 'invalid_capacity', null::uuid; return;
  end if;

  insert into public.vehicles(driver_id, vehicle_type, plate, model, capacity_kg)
  values (p_driver_id, p_vehicle_type, upper(p_plate), p_model, p_capacity_kg)
  on conflict (plate) do nothing
  returning id into v_id;

  if v_id is null then
    select id into v_id from public.vehicles where plate = upper(p_plate);
    return query select true, 'already_exists', v_id; return;
  end if;

  return query select true, 'created', v_id;
end;
$$;

comment on function public.create_vehicle(uuid,public.vehicle_type,text,text,integer) is
  'Cria veículo (driver-owned). SECURITY DEFINER, ADR-011 D4. driver self, super/admin ou system. Idempotente via plate.';

-- ============================================================================
-- set_current_vehicle(p_vehicle_id)
-- driver dono do veículo OU super/admin. Seta drivers.current_vehicle_id.
-- ============================================================================
create or replace function public.set_current_vehicle(
  p_vehicle_id uuid
) returns table(ok boolean, reason text)
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_caller  uuid := auth.uid();
  v_driver  uuid;
begin
  select driver_id into v_driver from public.vehicles where id = p_vehicle_id;
  if not found then
    return query select false, 'vehicle_not_found'; return;
  end if;

  if v_caller is not null then
    if not public.is_super_or_admin()
       and not exists (select 1 from public.drivers d where d.id = v_driver and d.user_id = v_caller) then
      return query select false, 'not_authorized'; return;
    end if;
  end if;

  update public.drivers set current_vehicle_id = p_vehicle_id where id = v_driver;

  return query select true, 'set';
end;
$$;

comment on function public.set_current_vehicle(uuid) is
  'Define veículo atual do driver. SECURITY DEFINER, ADR-011 D4. driver dono ou super/admin.';

-- ============================================================================
-- update_driver_status(p_driver_id, p_new_status)
-- super_admin/admin apenas (sem system: mutação de identidade, alinha a 0019).
-- p_new_status in ('active','suspended','blocked') — não permite voltar a 'pending'.
-- ============================================================================
create or replace function public.update_driver_status(
  p_driver_id   uuid,
  p_new_status  public.driver_account_status
) returns table(ok boolean, reason text)
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_caller uuid := auth.uid();
begin
  if v_caller is null or not public.is_super_or_admin() then
    return query select false, 'not_authorized'; return;
  end if;

  if p_new_status not in ('active','suspended','blocked') then
    return query select false, 'invalid_status'; return;
  end if;

  if not exists (select 1 from public.drivers where id = p_driver_id) then
    return query select false, 'driver_not_found'; return;
  end if;

  update public.drivers set account_status = p_new_status where id = p_driver_id;

  return query select true, 'updated';
end;
$$;

comment on function public.update_driver_status(uuid,public.driver_account_status) is
  'Ativa/suspende/bloqueia driver. SECURITY DEFINER, ADR-011 D4. super/admin apenas (sem system).';

-- ============================================================================
-- Grants (least-privilege, Modelo B). revoke PUBLIC; EXECUTE em service_role +
-- authenticated (user-facing). Nenhum DML a authenticated. anon: nada.
-- ============================================================================
revoke all on function
  public.create_organization(text,text,text),
  public.create_business(uuid,text),
  public.create_business_location(uuid,text,text,double precision,double precision,text,text),
  public.create_vehicle(uuid,public.vehicle_type,text,text,integer),
  public.set_current_vehicle(uuid),
  public.update_driver_status(uuid,public.driver_account_status)
from public;

grant execute on function
  public.create_organization(text,text,text),
  public.create_business(uuid,text),
  public.create_business_location(uuid,text,text,double precision,double precision,text,text),
  public.create_vehicle(uuid,public.vehicle_type,text,text,integer),
  public.set_current_vehicle(uuid),
  public.update_driver_status(uuid,public.driver_account_status)
to service_role, authenticated;