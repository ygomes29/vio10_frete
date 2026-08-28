-- test_vio10_authz.sql — Testes de autorização RLS/RBAC (Sessão 04, ADR-009).
-- Valida: isolamento cross-tenant, isolamento de driver, papel sem policy vê 0,
-- bypass da máquina de estados via PostgREST direto está FECHADO, e a checagem
-- auth.uid() nas RPCs DEFINER (Modelo B) bloqueia driver errado.
--
-- Executa em begin/rollback (clean-slate). Simula usuários via:
--   set local role authenticated;  -- ativa policies "to authenticated"
--   select set_config('request.jwt.claims', json_build_object('sub',<uuid>)::text, true);
-- auth.uid() lê 'sub' do JWT; as helpers DEFINER resolvem papel/org/driver.
--
-- Resultados consolidados em az_results(test, expected, actual, pass).

set search_path to public, extensions;
begin;

create temp table az_ids(k text primary key, v uuid);
create temp table az_results(test text, expected text, actual text, pass boolean);

-- ---- SETUP (como owner, antes de set role) ----
do $$
declare
  v_pt geography(Point,4326) := ST_SetSRID(ST_MakePoint(-43.8589,-22.9702),4326)::geography(Point,4326);
  v_orgA uuid; v_orgB uuid; v_bizA uuid; v_bizB uuid;
  v_uA uuid; v_uB uuid; v_uD uuid; v_uD2 uuid; v_uN uuid; v_uAd uuid;
  v_dD uuid; v_dD2 uuid;
  v_reqA uuid; v_reqB uuid; v_rndA uuid; v_rndB uuid; v_oDA uuid; v_oD2B uuid;
begin
  insert into public.organizations(name) values('OrgA') returning id into v_orgA;
  insert into public.organizations(name) values('OrgB') returning id into v_orgB;
  insert into public.businesses(organization_id,name) values(v_orgA,'BizA') returning id into v_bizA;
  insert into public.businesses(organization_id,name) values(v_orgB,'BizB') returning id into v_bizB;

  -- 6 usuários (auth.users). A trigger handle_new_user (0018) cria profiles; o insert
  -- manual abaixo é idempotente (on conflict) por compat/segurança.
  v_uA  := gen_random_uuid(); insert into auth.users(id,email) values(v_uA,  v_uA::text||'@t.local');  insert into public.profiles(id) values(v_uA)  on conflict (id) do nothing;
  v_uB  := gen_random_uuid(); insert into auth.users(id,email) values(v_uB,  v_uB::text||'@t.local');  insert into public.profiles(id) values(v_uB)  on conflict (id) do nothing;
  v_uD  := gen_random_uuid(); insert into auth.users(id,email) values(v_uD,  v_uD::text||'@t.local');  insert into public.profiles(id) values(v_uD)  on conflict (id) do nothing;
  v_uD2 := gen_random_uuid(); insert into auth.users(id,email) values(v_uD2,v_uD2::text||'@t.local'); insert into public.profiles(id) values(v_uD2) on conflict (id) do nothing;
  v_uN  := gen_random_uuid(); insert into auth.users(id,email) values(v_uN,  v_uN::text||'@t.local');  insert into public.profiles(id) values(v_uN)  on conflict (id) do nothing;
  v_uAd := gen_random_uuid(); insert into auth.users(id,email) values(v_uAd,v_uAd::text||'@t.local'); insert into public.profiles(id) values(v_uAd) on conflict (id) do nothing;

  -- papéis (platform_role enum: super_admin/admin/operator; driver NÃO entra aqui —
  -- motorista é identificado pela linha em drivers, via my_driver_id()).
  insert into public.user_platform_roles(user_id,role) values(v_uAd,'admin');
  insert into public.organization_memberships(user_id,organization_id,role) values(v_uA,v_orgA,'business_user'),(v_uB,v_orgB,'business_user');

  -- drivers
  insert into public.drivers(user_id,full_name,phone,account_status,current_availability_status)
    values(v_uD,'DriverD','1','active','available') returning id into v_dD;
  insert into public.drivers(user_id,full_name,phone,account_status,current_availability_status)
    values(v_uD2,'DriverD2','2','active','available') returning id into v_dD2;
  insert into public.driver_locations(driver_id,position,captured_at) values(v_dD,v_pt,now()),(v_dD2,v_pt,now());

  -- corridas
  insert into public.delivery_requests(organization_id,business_id,
    pickup_address,pickup_latitude,pickup_longitude,pickup_point,pickup_contact_phone,
    delivery_address,delivery_latitude,delivery_longitude,delivery_point,delivery_contact_phone,
    vehicle_required,status)
  values(v_orgA,v_bizA,'coletaA',-22.9702,-43.8589,v_pt,'1','entregaA',-22.9750,-43.8600,
    ST_SetSRID(ST_MakePoint(-43.8600,-22.9750),4326)::geography(Point,4326),'1','motorcycle','searching_driver')
  returning id into v_reqA;
  insert into public.delivery_requests(organization_id,business_id,
    pickup_address,pickup_latitude,pickup_longitude,pickup_point,pickup_contact_phone,
    delivery_address,delivery_latitude,delivery_longitude,delivery_point,delivery_contact_phone,
    vehicle_required,status)
  values(v_orgB,v_bizB,'coletaB',-22.9702,-43.8589,v_pt,'2','entregaB',-22.9750,-43.8600,
    ST_SetSRID(ST_MakePoint(-43.8600,-22.9750),4326)::geography(Point,4326),'2','motorcycle','searching_driver')
  returning id into v_reqB;

  insert into public.dispatch_rounds(delivery_request_id,round_number,search_radius_m,max_candidates,driver_offer_cents,expires_at)
    values(v_reqA,1,2000,5,1000,now()+interval '5 min') returning id into v_rndA;
  insert into public.dispatch_rounds(delivery_request_id,round_number,search_radius_m,max_candidates,driver_offer_cents,expires_at)
    values(v_reqB,1,2000,5,1000,now()+interval '5 min') returning id into v_rndB;
  insert into public.delivery_offers(delivery_request_id,dispatch_round_id,driver_id,driver_offer_cents,expires_at)
    values(v_reqA,v_rndA,v_dD,1000,now()+interval '5 min') returning id into v_oDA;
  insert into public.delivery_offers(delivery_request_id,dispatch_round_id,driver_id,driver_offer_cents,expires_at)
    values(v_reqB,v_rndB,v_dD2,1000,now()+interval '5 min') returning id into v_oD2B;

  insert into az_ids values
    ('orgA',v_orgA),('orgB',v_orgB),('userA',v_uA),('userB',v_uB),('userD',v_uD),
    ('userD2',v_uD2),('userN',v_uN),('userAdmin',v_uAd),('dD',v_dD),('dD2',v_dD2),
    ('reqA',v_reqA),('reqB',v_reqB),('oDA',v_oDA),('oD2B',v_oD2B);
end $$;

-- helper local de asserção
create or replace function pg_temp.az(t text, exp text, act text) returns void
language plpgsql as $$
begin
  insert into az_results(test,expected,actual,pass) values(t,exp,act,exp=act);
end $$;
-- temp tables/função criadas pelo owner; concededidas a authenticated para uso após set role.
grant all on az_ids, az_results to authenticated;
grant execute on function pg_temp.az(text,text,text) to authenticated;

-- ---- A partir daqui: simula usuários sob RLS authenticated ----
set local role authenticated;

-- ===== TEST 1: business_user A vê só reqA (1), 0 de orgB =====
select set_config('request.jwt.claims', json_build_object('sub',(select v from az_ids where k='userA'))::text, true);
select pg_temp.az('userA total delivery_requests','1',(select count(*)::text from public.delivery_requests));
select pg_temp.az('userA vê 0 de orgB','0',(select count(*)::text from public.delivery_requests where organization_id=(select v from az_ids where k='orgB')));
select pg_temp.az('userA vê organizations só a sua','1',(select count(*)::text from public.organizations));
select pg_temp.az('userA vê businesses só da sua org','1',(select count(*)::text from public.businesses));

-- ===== TEST 2: business_user B vê só reqB =====
select set_config('request.jwt.claims', json_build_object('sub',(select v from az_ids where k='userB'))::text, true);
select pg_temp.az('userB total delivery_requests','1',(select count(*)::text from public.delivery_requests));
select pg_temp.az('userB vê 0 de orgA','0',(select count(*)::text from public.delivery_requests where organization_id=(select v from az_ids where k='orgA')));

-- ===== TEST 3: driver D vê só reqA (offer dirigida a ele), 1 offer, 1 driver (self) =====
select set_config('request.jwt.claims', json_build_object('sub',(select v from az_ids where k='userD'))::text, true);
select pg_temp.az('driverD vê só reqA','1',(select count(*)::text from public.delivery_requests));
select pg_temp.az('driverD vê 0 de orgB','0',(select count(*)::text from public.delivery_requests where organization_id=(select v from az_ids where k='orgB')));
select pg_temp.az('driverD vê 1 offer (a dele)','1',(select count(*)::text from public.delivery_offers));
select pg_temp.az('driverD vê só a própria linha em drivers','1',(select count(*)::text from public.drivers));

-- ===== TEST 4: driver D2 vê só reqB =====
select set_config('request.jwt.claims', json_build_object('sub',(select v from az_ids where k='userD2'))::text, true);
select pg_temp.az('driverD2 vê só reqB','1',(select count(*)::text from public.delivery_requests));
select pg_temp.az('driverD2 vê 0 de orgA','0',(select count(*)::text from public.delivery_requests where organization_id=(select v from az_ids where k='orgA')));

-- ===== TEST 5: user sem papel/membership/driver vê 0 (default-deny) =====
select set_config('request.jwt.claims', json_build_object('sub',(select v from az_ids where k='userN'))::text, true);
select pg_temp.az('userN vê 0 delivery_requests','0',(select count(*)::text from public.delivery_requests));
select pg_temp.az('userN vê 0 organizations','0',(select count(*)::text from public.organizations));
select pg_temp.az('userN vê 0 drivers','0',(select count(*)::text from public.drivers));

-- ===== TEST 6: platform admin vê tudo (cross-tenant) =====
select set_config('request.jwt.claims', json_build_object('sub',(select v from az_ids where k='userAdmin'))::text, true);
select pg_temp.az('admin vê 2 delivery_requests','2',(select count(*)::text from public.delivery_requests));
select pg_temp.az('admin vê 2 organizations','2',(select count(*)::text from public.organizations));
select pg_temp.az('admin vê 2 drivers','2',(select count(*)::text from public.drivers));

-- ===== TEST 7: bypass da máquina de estados via PostgREST direto está FECHADO =====
-- authenticated não tem UPDATE em delivery_requests; tentar mudar status deve falhar.
select set_config('request.jwt.claims', json_build_object('sub',(select v from az_ids where k='userD'))::text, true);
do $$
declare
  v_reqA uuid := (select v from az_ids where k='reqA');
  v_blocked boolean := false;
begin
  begin
    update public.delivery_requests set status='delivered' where id=v_reqA;
  exception when insufficient_privilege or others then
    v_blocked := true;
  end;
  -- se não foi bloqueado, é um buraco.
  insert into az_results(test,expected,actual,pass)
  values('bypass UPDATE delivery_requests blocked','true',v_blocked::text, v_blocked);
end $$;

-- ===== TEST 8: RPC respond_to_offer bloqueia driver errado (chechagem auth.uid) =====
-- driverD tenta responder a offer dirigida a driverD2 (passa driver_id do D2):
-- deve retornar (false,'not_authorized').
do $$
declare
  r record;
  v_oD2B uuid := (select v from az_ids where k='oD2B');
  v_dD2  uuid := (select v from az_ids where k='dD2');
begin
  select * into r from public.respond_to_offer(v_oD2B, v_dD2, 'accept');
  insert into az_results(test,expected,actual,pass)
  values('respond_to_offer bloqueia driver errado','not_authorized',r.reason, r.reason='not_authorized');
end $$;

-- ===== TEST 9: driverD responde a própria offer -> OK (caminho legítimo) =====
do $$
declare
  r record;
  v_oDA uuid := (select v from az_ids where k='oDA');
  v_dD  uuid := (select v from az_ids where k='dD');
begin
  select * into r from public.respond_to_offer(v_oDA, v_dD, 'accept');
  insert into az_results(test,expected,actual,pass)
  values('respond_to_offer próprio driver ok','responded',r.reason, r.reason='responded' or r.reason='already_responded');
end $$;

-- ===== RESULTADO FINAL (único resultset consolidado) =====
select
  count(*) as total,
  sum((pass)::int) as passed,
  count(*) filter (where not pass) as failed,
  (select string_agg(test||' ['||expected||'/'||actual||']', ' | ' order by test)
   from az_results where not pass) as failures,
  (select string_agg(test||'=OK', ' | ' order by test)
   from az_results where pass) as passing
from az_results;

rollback;