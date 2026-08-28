-- test_vio10_creation.sql — Criação da corrida + gestão de entidades (Sessão 06, ADR-011).
-- Valida: create_organization/business/business_location, create_vehicle, set_current_vehicle,
-- update_driver_status, create_delivery_request (draft + itens + evento, PostGIS points,
-- external_reference dedup, authz system/admin/org-member, cross-tenant negado).
--
-- Executa em begin/rollback (clean-slate). Fase 1 (owner): setup (auth.users -> profiles via
-- trigger 0018, papéis, memberships, drivers, orgs/businesses baseline) + helpers DEFINER.
-- Fase 2 (authenticated): simula caller via set_config('request.jwt.claims', sub=uuid).
-- Resultados consolidados em cr_results(test, expected, actual, pass).

set search_path to public, extensions;
begin;

create temp table cr_ids(k text primary key, v uuid);
create temp table cr_results(test text, expected text, actual text, pass boolean);

-- ============================ FASE 1: SETUP (owner) ============================
do $$
declare
  v_orgA uuid; v_orgB uuid; v_bizA uuid; v_bizB uuid;
  v_uSuper uuid; v_uAdmin uuid; v_uOp uuid; v_uBO uuid; v_uBU uuid; v_uDrv uuid; v_uDrv2 uuid;
begin
  -- auth.users; trigger handle_new_user (0018) cria profiles.
  v_uSuper := gen_random_uuid(); insert into auth.users(id,email) values(v_uSuper,'super@c.local');
  v_uAdmin := gen_random_uuid(); insert into auth.users(id,email) values(v_uAdmin,'admin@c.local');
  v_uOp   := gen_random_uuid(); insert into auth.users(id,email) values(v_uOp,'op@c.local');
  v_uBO   := gen_random_uuid(); insert into auth.users(id,email) values(v_uBO,'bo@c.local');
  v_uBU   := gen_random_uuid(); insert into auth.users(id,email) values(v_uBU,'bu@c.local');
  v_uDrv  := gen_random_uuid(); insert into auth.users(id,email) values(v_uDrv,'drv@c.local');
  v_uDrv2 := gen_random_uuid(); insert into auth.users(id,email) values(v_uDrv2,'drv2@c.local');

  -- papéis platform (owner path: provisionamento)
  insert into public.user_platform_roles(user_id,role)
    values(v_uSuper,'super_admin'),(v_uAdmin,'admin'),(v_uOp,'operator');

  -- orgs/businesses baseline (owner path)
  insert into public.organizations(name) values('OrgA') returning id into v_orgA;
  insert into public.organizations(name) values('OrgB') returning id into v_orgB;
  insert into public.businesses(organization_id,name) values(v_orgA,'BizA') returning id into v_bizA;
  insert into public.businesses(organization_id,name) values(v_orgB,'BizB') returning id into v_bizB;

  -- memberships (uBO owner de orgA, uBU user de orgA)
  insert into public.organization_memberships(user_id,organization_id,role)
    values(v_uBO,v_orgA,'business_owner'),(v_uBU,v_orgA,'business_user');

  -- drivers (owner path; create_driver exige admin autenticado, não serve p/ setup).
  -- Não capturamos o row id aqui (buscamos por user_id nos testes) p/ não sobrescrever
  -- o uuid do user (v_uDrv/v_uDrv2 são os auth.users id).
  insert into public.drivers(user_id,full_name,phone)
    values(v_uDrv,'Drv Um','111'),(v_uDrv2,'Drv Dois','222');

  insert into cr_ids values
    ('orgA',v_orgA),('orgB',v_orgB),('bizA',v_bizA),('bizB',v_bizB),
    ('uSuper',v_uSuper),('uAdmin',v_uAdmin),('uOp',v_uOp),('uBO',v_uBO),
    ('uBU',v_uBU),('uDrv',v_uDrv),('uDrv2',v_uDrv2);
end $$;

-- helper local de asserção
create or replace function pg_temp.cr(t text, exp text, act text) returns void
language plpgsql as $$
begin
  insert into cr_results(test,expected,actual,pass) values(t,exp,act,exp=act);
end $$;
grant all on cr_ids, cr_results to authenticated, anon;
grant execute on function pg_temp.cr(text,text,text) to authenticated, anon;

-- Helpers de inspeção SECURITY DEFINER (lê como postgres, bypass RLS). Necessários porque
-- assertions rodam sob `set local role authenticated` (RLS filtraria/cross-tenant).
create or replace function pg_temp.dr_status(p_id uuid) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select status::text from public.delivery_requests where id = p_id $$;
create or replace function pg_temp.dr_items(p_id uuid) returns int
language sql security definer set search_path = public, pg_catalog
as $$ select count(*) from public.delivery_items where delivery_request_id = p_id $$;
create or replace function pg_temp.dr_event_created(p_id uuid) returns boolean
language sql security definer set search_path = public, pg_catalog
as $$ select exists(select 1 from public.delivery_events where delivery_request_id = p_id and event_type = 'delivery_created') $$;
create or replace function pg_temp.dr_pickup_xy(p_id uuid) returns text
language sql security definer set search_path = public, extensions, pg_catalog
as $$ select round(st_x(pickup_point::geometry)::numeric,4)||','||round(st_y(pickup_point::geometry)::numeric,4) from public.delivery_requests where id = p_id $$;
create or replace function pg_temp.loc_point_set(p_id uuid) returns boolean
language sql security definer set search_path = public, pg_catalog
as $$ select point is not null from public.business_locations where id = p_id $$;
create or replace function pg_temp.vehicle_plate(p_id uuid) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select plate from public.vehicles where id = p_id $$;
create or replace function pg_temp.driver_acc_status(p_id uuid) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select account_status::text from public.drivers where id = p_id $$;
grant execute on function
  pg_temp.dr_status(uuid), pg_temp.dr_items(uuid), pg_temp.dr_event_created(uuid),
  pg_temp.dr_pickup_xy(uuid), pg_temp.loc_point_set(uuid), pg_temp.vehicle_plate(uuid),
  pg_temp.driver_acc_status(uuid)
to authenticated;

-- ============================ FASE 2: RPCs (authenticated) ============================
set local role authenticated;

-- ===== T1: create_organization =====
select set_config('request.jwt.claims', json_build_object('sub',(select v from cr_ids where k='uSuper'))::text, true);
do $$
declare r record; v_id uuid; begin
  select * into r from public.create_organization('OrgNew', null, null);
  insert into cr_results(test,expected,actual,pass) values('T1 super cria org','created',r.reason, r.ok and r.reason='created' and r.organization_id is not null);
  insert into cr_ids values('orgNew', r.organization_id);
end $$;
select set_config('request.jwt.claims', json_build_object('sub',(select v from cr_ids where k='uBU'))::text, true);
do $$
declare r record; begin
  select * into r from public.create_organization('OrgX', null, null);
  insert into cr_results(test,expected,actual,pass) values('T1b business_user nao cria org','not_authorized',r.reason, r.reason='not_authorized');
end $$;

-- ===== T2: create_business (business_owner da própria org ok; outra org negado) =====
select set_config('request.jwt.claims', json_build_object('sub',(select v from cr_ids where k='uBO'))::text, true);
do $$
declare r record; v_orgA uuid := (select v from cr_ids where k='orgA'); v_orgB uuid := (select v from cr_ids where k='orgB'); begin
  select * into r from public.create_business(v_orgA, 'BizA2');
  insert into cr_results(test,expected,actual,pass) values('T2 owner cria business na propria org','created',r.reason, r.ok and r.reason='created');
  select * into r from public.create_business(v_orgB, 'BizX');
  insert into cr_results(test,expected,actual,pass) values('T2b owner cria business em outra org negado','not_authorized',r.reason, r.reason='not_authorized');
end $$;

-- ===== T3: create_business_location (point montado; outra org negado; lat parcial invalid) =====
do $$
declare r record; v_bizA uuid := (select v from cr_ids where k='bizA'); v_bizB uuid := (select v from cr_ids where k='bizB'); begin
  select * into r from public.create_business_location(v_bizA, 'Matriz', 'Rua A 100', -23.5, -46.0, 'Contato', '333');
  insert into cr_results(test,expected,actual,pass) values('T3 owner cria location com latlng','created',r.reason, r.ok and r.reason='created');
  insert into cr_ids values('locA', r.business_location_id);
  select * into r from public.create_business_location(v_bizB, 'Filial', 'Rua B', -23.6, -46.1, null, '444');
  insert into cr_results(test,expected,actual,pass) values('T3b location de business de outra org negado','not_authorized',r.reason, r.reason='not_authorized');
  select * into r from public.create_business_location(v_bizA, 'X', 'Rua', -23.5, null, null, '333');
  insert into cr_results(test,expected,actual,pass) values('T3c lat sem lng invalid','invalid_latlng',r.reason, r.reason='invalid_latlng');
end $$;
select pg_temp.cr('T3d point montado','true', pg_temp.loc_point_set((select v from cr_ids where k='locA'))::text);

-- ===== T4: create_vehicle (driver self ok; outro driver negado; admin ok; placa duplicada already_exists) =====
select set_config('request.jwt.claims', json_build_object('sub',(select v from cr_ids where k='uDrv'))::text, true);
do $$
declare r record; v_drv uuid; v_drv2 uuid; begin
  select id into v_drv  from public.drivers where user_id = (select v from cr_ids where k='uDrv');
  select id into v_drv2 from public.drivers where user_id = (select v from cr_ids where k='uDrv2');
  select * into r from public.create_vehicle(v_drv, 'motorcycle', 'AAA1111', 'Honda CG', 100);
  insert into cr_results(test,expected,actual,pass) values('T4 driver cria proprio veiculo','created',r.reason, r.ok and r.reason='created');
  insert into cr_ids values('vehDrv', r.vehicle_id);
  -- mesmo driver, mesma placa -> on conflict (plate) do nothing -> already_exists
  select * into r from public.create_vehicle(v_drv, 'motorcycle', 'AAA1111', 'Honda', 100);
  insert into cr_results(test,expected,actual,pass) values('T4b placa duplicada already_exists','already_exists',r.reason, r.reason='already_exists');
  -- driver tenta criar veículo para OUTRO driver
  select * into r from public.create_vehicle(v_drv2, 'motorcycle', 'ZZZ9999', 'Yamaha', 100);
  insert into cr_results(test,expected,actual,pass) values('T4c driver cria veiculo de outro negado','not_authorized',r.reason, r.reason='not_authorized');
end $$;
select set_config('request.jwt.claims', json_build_object('sub',(select v from cr_ids where k='uAdmin'))::text, true);
do $$
declare r record; v_drv2 uuid; begin
  select id into v_drv2 from public.drivers where user_id = (select v from cr_ids where k='uDrv2');
  select * into r from public.create_vehicle(v_drv2, 'car', 'BBB2222', 'Fiat', 500);
  insert into cr_results(test,expected,actual,pass) values('T4d admin cria veiculo','created',r.reason, r.ok and r.reason='created');
  insert into cr_ids values('vehDrv2', r.vehicle_id);
end $$;
select pg_temp.cr('T4e placa normalizada upper','AAA1111', pg_temp.vehicle_plate((select v from cr_ids where k='vehDrv')));

-- ===== T5: set_current_vehicle (dono ok; veículo de outro negado) =====
select set_config('request.jwt.claims', json_build_object('sub',(select v from cr_ids where k='uDrv'))::text, true);
do $$
declare r record; v_vehDrv uuid := (select v from cr_ids where k='vehDrv'); v_vehDrv2 uuid := (select v from cr_ids where k='vehDrv2'); begin
  select * into r from public.set_current_vehicle(v_vehDrv);
  insert into cr_results(test,expected,actual,pass) values('T5 driver seta proprio veiculo','set',r.reason, r.ok and r.reason='set');
  select * into r from public.set_current_vehicle(v_vehDrv2);
  insert into cr_results(test,expected,actual,pass) values('T5b seta veiculo de outro negado','not_authorized',r.reason, r.reason='not_authorized');
end $$;

-- ===== T6: update_driver_status (admin ativa; business_user negado; pending invalid) =====
select set_config('request.jwt.claims', json_build_object('sub',(select v from cr_ids where k='uAdmin'))::text, true);
do $$
declare r record; v_drv uuid; begin
  select id into v_drv from public.drivers where user_id = (select v from cr_ids where k='uDrv');
  select * into r from public.update_driver_status(v_drv, 'active');
  insert into cr_results(test,expected,actual,pass) values('T6 admin ativa driver','updated',r.reason, r.ok and r.reason='updated');
  insert into cr_ids values('drvRow', v_drv);
  select * into r from public.update_driver_status(v_drv, 'pending');
  insert into cr_results(test,expected,actual,pass) values('T6b pending invalid','invalid_status',r.reason, r.reason='invalid_status');
end $$;
select set_config('request.jwt.claims', json_build_object('sub',(select v from cr_ids where k='uBU'))::text, true);
do $$
declare r record; v_drv uuid := (select v from cr_ids where k='drvRow'); begin
  select * into r from public.update_driver_status(v_drv, 'suspended');
  insert into cr_results(test,expected,actual,pass) values('T6c business_user nao muta status','not_authorized',r.reason, r.reason='not_authorized');
end $$;
select pg_temp.cr('T6d driver ativo','active', pg_temp.driver_acc_status((select v from cr_ids where k='drvRow')));

-- ===== Helper p/ chamar create_delivery_request com defaults =====
-- ===== T7: business_user cria corrida (orgA/bizA) -> draft + 2 itens + evento + point =====
do $$
declare r record; v_orgA uuid := (select v from cr_ids where k='orgA'); v_bizA uuid := (select v from cr_ids where k='bizA');
        v_items jsonb := '[{"description":"Caixa A","quantity":2,"weight_g":5000},{"description":"Caixa B","quantity":1}]'::jsonb; begin
  select * into r from public.create_delivery_request(
    v_orgA, v_bizA, null,
    'Rua Pickup 1', -23.5000, -46.0000, 'Pickup Nome', '555',
    'Rua Delivery 2', -23.5500, -46.0500, 'Delivery Nome', '666',
    'motorcycle', 'standard', null, 'dashboard', null, null, 'Entregar na portaria', v_items, null);
  insert into cr_results(test,expected,actual,pass) values('T7 business_user cria corrida','created',r.reason, r.ok and r.reason='created');
  insert into cr_ids values('dr1', r.delivery_request_id);
end $$;
select pg_temp.cr('T7b status draft','draft', pg_temp.dr_status((select v from cr_ids where k='dr1')));
select pg_temp.cr('T7c 2 itens','2', pg_temp.dr_items((select v from cr_ids where k='dr1'))::text);
select pg_temp.cr('T7d evento delivery_created','true', pg_temp.dr_event_created((select v from cr_ids where k='dr1'))::text);
select pg_temp.cr('T7e pickup point xy','-46.0000,-23.5000', pg_temp.dr_pickup_xy((select v from cr_ids where k='dr1')));

-- ===== T8: cross-tenant (uBU de orgA p/ orgB) -> not_authorized =====
do $$
declare r record; v_orgB uuid := (select v from cr_ids where k='orgB'); v_bizB uuid := (select v from cr_ids where k='bizB');
        v_items jsonb := '[{"description":"X","quantity":1}]'::jsonb; begin
  select * into r from public.create_delivery_request(
    v_orgB, v_bizB, null, 'R', -23.5, -46.0, null, '555', 'R2', -23.55, -46.05, null, '666',
    'motorcycle', 'standard', null, 'dashboard', null, null, null, v_items, null);
  insert into cr_results(test,expected,actual,pass) values('T8 cross-tenant negado','not_authorized',r.reason, r.reason='not_authorized');
end $$;

-- ===== T9: admin cria -> ok =====
select set_config('request.jwt.claims', json_build_object('sub',(select v from cr_ids where k='uAdmin'))::text, true);
do $$
declare r record; v_orgA uuid := (select v from cr_ids where k='orgA'); v_bizA uuid := (select v from cr_ids where k='bizA');
        v_items jsonb := '[{"description":"Y","quantity":1}]'::jsonb; begin
  select * into r from public.create_delivery_request(
    v_orgA, v_bizA, null, 'R', -23.5, -46.0, null, '555', 'R2', -23.55, -46.05, null, '666',
    'motorcycle', 'urgent', null, 'operator', null, null, null, v_items, null);
  insert into cr_results(test,expected,actual,pass) values('T9 admin cria corrida','created',r.reason, r.ok and r.reason='created');
end $$;

-- ===== T10: operator (is_platform_admin) cria -> ok =====
select set_config('request.jwt.claims', json_build_object('sub',(select v from cr_ids where k='uOp'))::text, true);
do $$
declare r record; v_orgA uuid := (select v from cr_ids where k='orgA'); v_bizA uuid := (select v from cr_ids where k='bizA');
        v_items jsonb := '[{"description":"Z","quantity":1}]'::jsonb; begin
  select * into r from public.create_delivery_request(
    v_orgA, v_bizA, null, 'R', -23.5, -46.0, null, '555', 'R2', -23.55, -46.05, null, '666',
    'motorcycle', 'standard', null, 'operator', null, null, null, v_items, null);
  insert into cr_results(test,expected,actual,pass) values('T10 operator cria corrida','created',r.reason, r.ok and r.reason='created');
end $$;

-- ===== T11: system path (auth.uid null) -> ok (integration) =====
select set_config('request.jwt.claims', '{}'::text, true);
do $$
declare r record; v_orgA uuid := (select v from cr_ids where k='orgA'); v_bizA uuid := (select v from cr_ids where k='bizA');
        v_items jsonb := '[{"description":"Sys","quantity":1}]'::jsonb; begin
  select * into r from public.create_delivery_request(
    v_orgA, v_bizA, null, 'R', -23.5, -46.0, null, '555', 'R2', -23.55, -46.05, null, '666',
    'motorcycle', 'standard', null, 'integration', null, null, null, v_items, null);
  insert into cr_results(test,expected,actual,pass) values('T11 system path cria corrida','created',r.reason, r.ok and r.reason='created');
end $$;

-- ===== T12: external_reference dedup (mesma org 2x -> already_exists; outra org mesmo ref -> ok) =====
select set_config('request.jwt.claims', json_build_object('sub',(select v from cr_ids where k='uBU'))::text, true);
do $$
declare r record; v_orgA uuid := (select v from cr_ids where k='orgA'); v_bizA uuid := (select v from cr_ids where k='bizA');
        v_items jsonb := '[{"description":"R","quantity":1}]'::jsonb; begin
  select * into r from public.create_delivery_request(
    v_orgA, v_bizA, null, 'R', -23.5, -46.0, null, '555', 'R2', -23.55, -46.05, null, '666',
    'motorcycle', 'standard', null, 'dashboard', 'EXT-1', null, null, v_items, null);
  insert into cr_results(test,expected,actual,pass) values('T12 cria com external_reference','created',r.reason, r.ok and r.reason='created');
  select * into r from public.create_delivery_request(
    v_orgA, v_bizA, null, 'R', -23.5, -46.0, null, '555', 'R2', -23.55, -46.05, null, '666',
    'motorcycle', 'standard', null, 'dashboard', 'EXT-1', null, null, v_items, null);
  insert into cr_results(test,expected,actual,pass) values('T12b mesmo ext_ref same org already_exists','already_exists',r.reason, r.reason='already_exists' and r.delivery_request_id is not null);
end $$;
-- outra org, mesmo external_reference -> permitido (UNIQUE é por org)
select set_config('request.jwt.claims', json_build_object('sub',(select v from cr_ids where k='uAdmin'))::text, true);
do $$
declare r record; v_orgB uuid := (select v from cr_ids where k='orgB'); v_bizB uuid := (select v from cr_ids where k='bizB');
        v_items jsonb := '[{"description":"R","quantity":1}]'::jsonb; begin
  select * into r from public.create_delivery_request(
    v_orgB, v_bizB, null, 'R', -23.5, -46.0, null, '555', 'R2', -23.55, -46.05, null, '666',
    'motorcycle', 'standard', null, 'dashboard', 'EXT-1', null, null, v_items, null);
  insert into cr_results(test,expected,actual,pass) values('T12c mesmo ext_ref outra org ok','created',r.reason, r.ok and r.reason='created');
end $$;

-- ===== T13: business_location_id de outro business -> location_not_in_business =====
select set_config('request.jwt.claims', json_build_object('sub',(select v from cr_ids where k='uBU'))::text, true);
do $$
declare r record; v_orgA uuid := (select v from cr_ids where k='orgA'); v_bizA uuid := (select v from cr_ids where k='bizA'); v_locA uuid := (select v from cr_ids where k='locA');
        v_items jsonb := '[{"description":"R","quantity":1}]'::jsonb; begin
  -- uBU cria p/ orgA/bizA mas passa location de... locA pertence a bizA (mesmo business), entao OK.
  -- Para testar location_not_in_business precisamos de uma location de outro business.
  -- locA eh de bizA; criamos location sob bizB (admin) e passamos aqui.
  null; -- placeholder: criamos locB abaixo
end $$;
-- cria location de bizB (admin) para o teste
select set_config('request.jwt.claims', json_build_object('sub',(select v from cr_ids where k='uAdmin'))::text, true);
do $$
declare r record; v_bizB uuid := (select v from cr_ids where k='bizB'); begin
  select * into r from public.create_business_location(v_bizB, 'LocB', 'Rua B', -23.6, -46.1, null, '444');
  insert into cr_ids values('locB', r.business_location_id);
end $$;
select set_config('request.jwt.claims', json_build_object('sub',(select v from cr_ids where k='uBU'))::text, true);
do $$
declare r record; v_orgA uuid := (select v from cr_ids where k='orgA'); v_bizA uuid := (select v from cr_ids where k='bizA'); v_locB uuid := (select v from cr_ids where k='locB');
        v_items jsonb := '[{"description":"R","quantity":1}]'::jsonb; begin
  select * into r from public.create_delivery_request(
    v_orgA, v_bizA, v_locB,   -- location pertence a bizB, nao a bizA
    'R', -23.5, -46.0, null, '555', 'R2', -23.55, -46.05, null, '666',
    'motorcycle', 'standard', null, 'dashboard', null, null, null, v_items, null);
  insert into cr_results(test,expected,actual,pass) values('T13 location de outro business','location_not_in_business',r.reason, r.reason='location_not_in_business');
end $$;

-- ===== T14: itens vazio/malformado -> invalid_items =====
do $$
declare r record; v_orgA uuid := (select v from cr_ids where k='orgA'); v_bizA uuid := (select v from cr_ids where k='bizA'); begin
  select * into r from public.create_delivery_request(
    v_orgA, v_bizA, null, 'R', -23.5, -46.0, null, '555', 'R2', -23.55, -46.05, null, '666',
    'motorcycle', 'standard', null, 'dashboard', null, null, null, '[]'::jsonb, null);
  insert into cr_results(test,expected,actual,pass) values('T14 itens vazios','invalid_items',r.reason, r.reason='invalid_items');
  select * into r from public.create_delivery_request(
    v_orgA, v_bizA, null, 'R', -23.5, -46.0, null, '555', 'R2', -23.55, -46.05, null, '666',
    'motorcycle', 'standard', null, 'dashboard', null, null, null,
    '[{"description":"","quantity":1}]'::jsonb, null);
  insert into cr_results(test,expected,actual,pass) values('T14b item sem description','invalid_items',r.reason, r.reason='invalid_items');
  select * into r from public.create_delivery_request(
    v_orgA, v_bizA, null, 'R', -23.5, -46.0, null, '555', 'R2', -23.55, -46.05, null, '666',
    'motorcycle', 'standard', null, 'dashboard', null, null, null,
    '[{"description":"Ok","quantity":0}]'::jsonb, null);
  insert into cr_results(test,expected,actual,pass) values('T14c item quantity 0','invalid_items',r.reason, r.reason='invalid_items');
end $$;

-- ===== T15: invalid_vehicle (vehicle_required null) =====
do $$
declare r record; v_orgA uuid := (select v from cr_ids where k='orgA'); v_bizA uuid := (select v from cr_ids where k='bizA');
        v_items jsonb := '[{"description":"R","quantity":1}]'::jsonb; begin
  select * into r from public.create_delivery_request(
    v_orgA, v_bizA, null, 'R', -23.5, -46.0, null, '555', 'R2', -23.55, -46.05, null, '666',
    null::public.vehicle_type, 'standard', null, 'dashboard', null, null, null, v_items, null);
  insert into cr_results(test,expected,actual,pass) values('T15 vehicle_required null','invalid_vehicle',r.reason, r.reason='invalid_vehicle');
end $$;

-- ===== T16: invalid_pickup (pickup_lat null) =====
do $$
declare r record; v_orgA uuid := (select v from cr_ids where k='orgA'); v_bizA uuid := (select v from cr_ids where k='bizA');
        v_items jsonb := '[{"description":"R","quantity":1}]'::jsonb; begin
  select * into r from public.create_delivery_request(
    v_orgA, v_bizA, null, 'R', null, -46.0, null, '555', 'R2', -23.55, -46.05, null, '666',
    'motorcycle', 'standard', null, 'dashboard', null, null, null, v_items, null);
  insert into cr_results(test,expected,actual,pass) values('T16 pickup_lat null','invalid_pickup',r.reason, r.reason='invalid_pickup');
end $$;

-- ===== RESULTADO FINAL (único resultset consolidado) =====
select
  count(*) as total,
  sum((pass)::int) as passed,
  count(*) filter (where not pass) as failed,
  (select string_agg(test||' ['||expected||'/'||actual||']', ' | ' order by test)
   from cr_results where not pass) as failures,
  (select string_agg(test||'=OK', ' | ' order by test)
   from cr_results where pass) as passing
from cr_results;

rollback;