-- test_vio10_dispatch.sql — Dispatch engine (Sessão 08, ADR-013).
-- Valida confirm_quote (user-scoped: quoted->searching_driver, confirma quote) e
-- open_dispatch_round (system-only: busca candidatos por PostGIS + eligibility, cria
-- dispatch_round + delivery_offers atomicamente, raio progressivo, guards de estado).
--
-- Geometria: pickup_point em (lat=0, lng=0) (equador). Drivers em (lat=0, lng=off): a
-- 1 grau de longitude no equador ~ 111320 m, logo:
--   off=0.001 -> ~111 m | off=0.01 -> ~1112 m | off=0.02 -> ~2224 m
-- Raios: 500 (só dClose) | 2000 (dClose+dMid) | 5000 (todos) | 50 (ninguém).
--
-- Executa em begin/rollback (clean-slate). Tudo roda como owner (system path,
-- auth.uid()=null); testes user-scoped injetam sub via set_config. Resultados em dp_results.

set search_path to public, extensions;
begin;

create temp table dp_ids(k text primary key, v uuid);
create temp table dp_results(test text, expected text, actual text, pass boolean);

-- cr: registra expected vs actual em dp_results.
create or replace function pg_temp.cr(t text, exp text, act text) returns void
language plpgsql as $$
begin
  insert into dp_results(test, expected, actual, pass) values (t, exp, act, exp = act);
  if exp <> act then
    raise notice 'FAIL %: exp=% act=%', t, exp, act;
  end if;
end $$;

-- ============================ SETUP (owner path) ============================
-- orgA (membro uBU) + orgB (membro uBU2, wrong-org). pricing rule orgA motorcycle.
-- 10 drivers em posições/estados variados para exercitar eligibility (D3).
do $$
declare
  v_orgA uuid; v_orgB uuid; v_bizA uuid; v_bizB uuid;
  v_uBU uuid; v_uBU2 uuid;
begin
  insert into public.organizations(name) values('OrgA') returning id into v_orgA;
  insert into public.organizations(name) values('OrgB') returning id into v_orgB;
  insert into public.businesses(organization_id,name) values(v_orgA,'BizA') returning id into v_bizA;
  insert into public.businesses(organization_id,name) values(v_orgB,'BizB') returning id into v_bizB;

  -- business users (auth.users -> profiles via trigger 0018)
  v_uBU  := gen_random_uuid(); insert into auth.users(id,email) values(v_uBU ,'bu@c.local');
  v_uBU2 := gen_random_uuid(); insert into auth.users(id,email) values(v_uBU2,'bu2@c.local');
  insert into public.organization_memberships(user_id,organization_id,role)
    values(v_uBU,v_orgA,'business_user'),(v_uBU2,v_orgB,'business_user');

  -- pricing rule orgA motorcycle (para create_quote funcionar)
  insert into public.pricing_rules
    (organization_id, vehicle_type, base_cents, per_km_cents, per_minute_cents,
     urgency_add_cents, min_price_cents, platform_fee_cents, is_active)
  values (v_orgA,'motorcycle',500,100,10,200,800,120,true);

  insert into dp_ids values
    ('orgA',v_orgA),('orgB',v_orgB),('bizA',v_bizA),('bizB',v_bizB),
    ('uBU',v_uBU),('uBU2',v_uBU2);
end $$;

-- mk_driver: cria auth.users(+profile via trigger) + driver + veículo (opcional) +
-- localização em (lat=0, lng=p_lng_off) com captured_at=now()-p_age_s + assignment ativa
-- opcional a p_asgn_dr. Retorna o driver_id.
create or replace function pg_temp.mk_driver(
  p_email text, p_full text, p_phone text,
  p_vtype text,             -- 'motorcycle' | 'car' | 'none'
  p_acc text,               -- driver_account_status
  p_avail text,             -- driver_availability_status
  p_lng_off double precision,
  p_age_s integer,           -- 0 = fresh
  p_has_active_asgn boolean default false,
  p_asgn_dr uuid default null
) returns uuid
language plpgsql
set search_path = public, extensions, pg_catalog
as $$
declare v_uid uuid := gen_random_uuid(); v_did uuid; v_vid uuid;
begin
  insert into auth.users(id,email) values(v_uid, p_email);
  insert into public.drivers(user_id, full_name, phone, account_status, current_availability_status)
    values(v_uid, p_full, p_phone, p_acc::public.driver_account_status,
           p_avail::public.driver_availability_status)
    returning id into v_did;
  if p_vtype <> 'none' then
    insert into public.vehicles(driver_id, vehicle_type, plate)
      values(v_did, p_vtype::public.vehicle_type, replace(p_full,' ','')||'-PLT')
      returning id into v_vid;
    update public.drivers set current_vehicle_id = v_vid where id = v_did;
  end if;
  insert into public.driver_locations(driver_id, position, captured_at)
    values (v_did, st_setsrid(st_makepoint(p_lng_off, 0.0), 4326)::geography(Point,4326),
            now() - (p_age_s || ' seconds')::interval);
  if p_has_active_asgn and p_asgn_dr is not null then
    insert into public.delivery_assignments(delivery_request_id, driver_id, status)
      values (p_asgn_dr, v_did, 'active');
  end if;
  return v_did;
end $$;

-- mk_draft: cria delivery_request em draft (system-scoped). pickup em (0,0).
create or replace function pg_temp.mk_draft(p_org uuid, p_biz uuid, p_vehicle text)
returns uuid language plpgsql
set search_path = public, extensions, pg_catalog
as $$
declare r record; v_items jsonb := '[{"description":"cx","quantity":1}]'::jsonb;
begin
  select * into r from public.create_delivery_request(
    p_org, p_biz, null,
    'Pickup', 0.0, 0.0, 'PN', '555',
    'Delivery', 0.0, 0.05, 'DN', '666',
    p_vehicle::public.vehicle_type, 'standard'::public.delivery_priority,
    null, 'dashboard', null, null, null, v_items, null);
  return r.delivery_request_id;
end $$;

-- mk_quoted: draft -> quoted (create_quote system). Retorna dr_id.
create or replace function pg_temp.mk_quoted(p_org uuid, p_biz uuid, p_vehicle text)
returns uuid language plpgsql
set search_path = public, extensions, pg_catalog
as $$
declare v_dr uuid; r record;
begin
  v_dr := pg_temp.mk_draft(p_org, p_biz, p_vehicle);
  select * into r from public.create_quote(v_dr, 10000, 600);
  return v_dr;
end $$;

-- ============================ Criação das corridas e drivers ============================
do $$
declare
  v_orgA uuid := (select v from dp_ids where k='orgA');
  v_bizA uuid := (select v from dp_ids where k='bizA');
  v_drAsgn uuid;
begin
  -- corridas quoted (para confirm_quote / wrong_state)
  insert into dp_ids values
    ('drMain',  pg_temp.mk_quoted(v_orgA,v_bizA,'motorcycle')),  -- T1/T2a/T2c
    ('dr2',     pg_temp.mk_quoted(v_orgA,v_bizA,'motorcycle')),  -- T2b system confirm
    ('drExpired', pg_temp.mk_quoted(v_orgA,v_bizA,'motorcycle'));-- T2d quote_expired

  -- drAsgn: quoted -> confirmado (searching) -> depois virará 'assigned' c/ assignment
  v_drAsgn := pg_temp.mk_quoted(v_orgA,v_bizA,'motorcycle');
  insert into dp_ids values ('drAsgn', v_drAsgn);

  -- drivers elegíveis (moto, active, available, fresh, sem assignment)
  insert into dp_ids values
    ('dClose', pg_temp.mk_driver('dc@c.local','Drv Close','111','motorcycle','active','available', 0.001, 0)),
    ('dMid',   pg_temp.mk_driver('dm@c.local','Drv Mid','222','motorcycle','active','available', 0.01,  0)),
    ('dFar',   pg_temp.mk_driver('df@c.local','Drv Far','333','motorcycle','active','available', 0.02,  0));

  -- drivers EXCLUÍDOS por eligibility (todos a ~111m, dentro do raio 500, mas desqualificados)
  insert into dp_ids values
    ('dCar',       pg_temp.mk_driver('dcar@c.local','Drv Car','444','car','active','available', 0.001, 0)),         -- veículo incompatível
    ('dSuspended', pg_temp.mk_driver('dsus@c.local','Drv Sus','555','motorcycle','suspended','available', 0.001, 0)),-- account_status
    ('dOffline',   pg_temp.mk_driver('doff@c.local','Drv Off','666','motorcycle','active','offline', 0.001, 0)),    -- availability
    ('dBusy',      pg_temp.mk_driver('dbusy@c.local','Drv Busy','777','motorcycle','active','busy', 0.001, 0)),     -- availability
    ('dStale',     pg_temp.mk_driver('dstale@c.local','Drv Stale','888','motorcycle','active','available', 0.001, 99999)), -- localização velha
    ('dNoVehicle', pg_temp.mk_driver('dnv@c.local','Drv NoV','999','none','active','available', 0.001, 0));        -- sem veículo corrente

  -- dAssigned: tem assignment ativa em drAsgn (criada acima) -> depois drAsgn vira 'assigned'
  insert into dp_ids values
    ('dAssigned', pg_temp.mk_driver('dasg@c.local','Drv Asg','000','motorcycle','active','available', 0.001, 0,
                                    true, v_drAsgn));
  -- drAsgn: searching -> assigned (owner; simula fim do ciclo p/ testar wrong_state)
  update public.delivery_requests set status = 'assigned'::public.delivery_status where id = v_drAsgn;

  -- drQuoted:quoted (NÃO confirmado) p/ T8b wrong_state=quoted
  insert into dp_ids values ('drQuoted', pg_temp.mk_quoted(v_orgA,v_bizA,'motorcycle'));

  -- drExpired: expira a quote pendente (status pending, expires_at no passado)
  update public.delivery_quotes set expires_at = now() - interval '1 second'
   where delivery_request_id = (select v from dp_ids where k='drExpired')
     and status = 'pending';
end $$;

-- Helpers de inspeção (DEFINER, bypass RLS) — leem estado p/ asserções.
create or replace function pg_temp.dr_status(p_id uuid) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select status::text from public.delivery_requests where id = p_id $$;
create or replace function pg_temp.quote_status(p_dr uuid) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select status::text from public.delivery_quotes where delivery_request_id=p_dr order by created_at desc limit 1 $$;
create or replace function pg_temp.quote_confirmed_at(p_dr uuid) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select case when confirmed_at is not null then 't' else 'f' end from public.delivery_quotes where delivery_request_id=p_dr order by created_at desc limit 1 $$;
create or replace function pg_temp.dispatch_started_set(p_dr uuid) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select case when dispatch_started_at is not null then 't' else 'f' end from public.delivery_requests where id=p_dr $$;
create or replace function pg_temp.has_event(p_dr uuid, p_ev text) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select case when exists(select 1 from public.delivery_events where delivery_request_id=p_dr and event_type=p_ev::public.delivery_event_type) then 't' else 'f' end $$;
create or replace function pg_temp.round_count(p_dr uuid) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select count(*)::text from public.dispatch_rounds where delivery_request_id=p_dr $$;
create or replace function pg_temp.open_round_count(p_dr uuid) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select count(*)::text from public.dispatch_rounds where delivery_request_id=p_dr and status='open' $$;
create or replace function pg_temp.offer_count(p_dr uuid) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select count(*)::text from public.delivery_offers where delivery_request_id=p_dr $$;
create or replace function pg_temp.offer_driver_ids(p_dr uuid) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select coalesce(string_agg(driver_id::text, ',' order by driver_id::text),'') from public.delivery_offers where delivery_request_id=p_dr $$;
create or replace function pg_temp.round_fields(p_dr uuid) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select (round_number::text||'|'||search_radius_m::text||'|'||max_candidates::text||'|'||driver_offer_cents::text||'|'||status::text) from public.dispatch_rounds where delivery_request_id=p_dr order by round_number desc limit 1 $$;
create or replace function pg_temp.round_expires_set(p_dr uuid) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select case when expires_at is not null then 't' else 'f' end from public.dispatch_rounds where delivery_request_id=p_dr order by round_number desc limit 1 $$;

-- ============================ T1: confirm_quote (membro org) ============================
do $$
declare v_ok boolean; v_reason text;
  v_dr uuid := (select v from dp_ids where k='drMain');
  v_uBU uuid := (select v from dp_ids where k='uBU');
begin
  perform set_config('request.jwt.claims', json_build_object('sub',v_uBU)::text, true);
  select ok, reason into v_ok, v_reason from public.confirm_quote(v_dr);
  perform pg_temp.cr('T1_ok','t', case when v_ok then 't' else 'f' end);
  perform pg_temp.cr('T1_reason','confirmed', coalesce(v_reason,''));
  perform pg_temp.cr('T1_dr_status','searching_driver', pg_temp.dr_status(v_dr));
  perform pg_temp.cr('T1_quote_status','confirmed', pg_temp.quote_status(v_dr));
  perform pg_temp.cr('T1_confirmed_at_set','t', pg_temp.quote_confirmed_at(v_dr));
  perform pg_temp.cr('T1_dispatch_started_set','t', pg_temp.dispatch_started_set(v_dr));
  perform pg_temp.cr('T1_ev_quote_confirmed','t', pg_temp.has_event(v_dr,'quote_confirmed'));
  perform pg_temp.cr('T1_ev_dispatch_started','t', pg_temp.has_event(v_dr,'dispatch_started'));
  -- reseta JWT -> system
  perform set_config('request.jwt.claims', '{}'::text, true);
end $$;

-- ============================ T2: authz confirm_quote ============================
do $$
declare v_ok boolean; v_reason text;
  v_drMain uuid := (select v from dp_ids where k='drMain');
  v_dr2 uuid := (select v from dp_ids where k='dr2');
  v_drExp uuid := (select v from dp_ids where k='drExpired');
  v_uBU2 uuid := (select v from dp_ids where k='uBU2');
begin
  -- T2a: membro de outra org (orgB) confirma drMain (orgA) -> not_authorized
  perform set_config('request.jwt.claims', json_build_object('sub',v_uBU2)::text, true);
  select ok, reason into v_ok, v_reason from public.confirm_quote(v_drMain);
  perform pg_temp.cr('T2a_ok','f', case when v_ok then 't' else 'f' end);
  perform pg_temp.cr('T2a_reason','not_authorized', coalesce(v_reason,''));
  perform set_config('request.jwt.claims', '{}'::text, true);

  -- T2b: system confirma dr2 -> ok
  select ok, reason into v_ok, v_reason from public.confirm_quote(v_dr2);
  perform pg_temp.cr('T2b_ok','t', case when v_ok then 't' else 'f' end);
  perform pg_temp.cr('T2b_reason','confirmed', coalesce(v_reason,''));
  perform pg_temp.cr('T2b_status','searching_driver', pg_temp.dr_status(v_dr2));

  -- T2c: re-confirm drMain (já searching_driver) -> wrong_state
  select ok, reason into v_ok, v_reason from public.confirm_quote(v_drMain);
  perform pg_temp.cr('T2c_ok','f', case when v_ok then 't' else 'f' end);
  perform pg_temp.cr('T2c_reason','wrong_state', coalesce(v_reason,''));

  -- T2d: quote expirada -> quote_expired (drExpired ainda quoted, quote pending expirada)
  select ok, reason into v_ok, v_reason from public.confirm_quote(v_drExp);
  perform pg_temp.cr('T2d_ok','f', case when v_ok then 't' else 'f' end);
  perform pg_temp.cr('T2d_reason','quote_expired', coalesce(v_reason,''));
  perform pg_temp.cr('T2d_still_quoted','quoted', pg_temp.dr_status(v_drExp));
end $$;

-- ============================ Cria deliveries searching_driver p/ rounds ============================
-- (drAuthz, drRound, drElig, drMax, drZero: confirmadas system -> searching_driver)
do $$
declare
  v_orgA uuid := (select v from dp_ids where k='orgA');
  v_bizA uuid := (select v from dp_ids where k='bizA');
  r record;
begin
  insert into dp_ids values
    ('drAuthz', pg_temp.mk_quoted(v_orgA,v_bizA,'motorcycle')),
    ('drRound', pg_temp.mk_quoted(v_orgA,v_bizA,'motorcycle')),
    ('drElig',  pg_temp.mk_quoted(v_orgA,v_bizA,'motorcycle')),
    ('drMax',   pg_temp.mk_quoted(v_orgA,v_bizA,'motorcycle')),
    ('drZero',  pg_temp.mk_quoted(v_orgA,v_bizA,'motorcycle'));
  -- confirma todas (system path)
  select * into r from public.confirm_quote((select v from dp_ids where k='drAuthz'));
  select * into r from public.confirm_quote((select v from dp_ids where k='drRound'));
  select * into r from public.confirm_quote((select v from dp_ids where k='drElig'));
  select * into r from public.confirm_quote((select v from dp_ids where k='drMax'));
  select * into r from public.confirm_quote((select v from dp_ids where k='drZero'));
end $$;

-- ============================ T3: open_dispatch_round rodada 1 (radius 2000) ============================
do $$
declare r record;
  v_dr uuid := (select v from dp_ids where k='drRound');
  v_dClose uuid := (select v from dp_ids where k='dClose');
  v_dMid uuid := (select v from dp_ids where k='dMid');
begin
  select * into r from public.open_dispatch_round(v_dr, 2000, 10, 1500, 120);
  perform pg_temp.cr('T3_ok','t', case when r.ok then 't' else 'f' end);
  perform pg_temp.cr('T3_reason','opened', coalesce(r.reason,''));
  perform pg_temp.cr('T3_count','2', coalesce(r.candidate_count::text,''));
  -- round criado: round_number=1, radius=2000, max=10, offer=1500, status=open
  perform pg_temp.cr('T3_round_fields','1|2000|10|1500|open', pg_temp.round_fields(v_dr));
  perform pg_temp.cr('T3_expires_set','t', pg_temp.round_expires_set(v_dr));
  perform pg_temp.cr('T3_offer_count','2', pg_temp.offer_count(v_dr));
  -- offers para dClose e dMid (ordenado por driver_id p/ comparação determinística)
  perform pg_temp.cr('T3_offer_drivers',
    least(v_dClose::text,v_dMid::text)||','||greatest(v_dClose::text,v_dMid::text),
    pg_temp.offer_driver_ids(v_dr));
  -- eventos round_opened + offer_created (2)
  perform pg_temp.cr('T3_ev_round_opened','t', pg_temp.has_event(v_dr,'round_opened'));
  perform pg_temp.cr('T3_ev_offer_created','t', pg_temp.has_event(v_dr,'offer_created'));
  -- status das offers: pending
  perform pg_temp.cr('T3_offers_pending','2',
    (select count(*)::text from public.delivery_offers where delivery_request_id=v_dr and status='pending'));
end $$;

-- ============================ T4: open_dispatch_round system-only ============================
do $$
declare r record;
  v_dr uuid := (select v from dp_ids where k='drAuthz');
  v_fake uuid := gen_random_uuid();
begin
  -- caller autenticado (sub falso) -> not_authorized (owner tem EXECUTE, checagem do corpo)
  perform set_config('request.jwt.claims', json_build_object('sub',v_fake)::text, true);
  select * into r from public.open_dispatch_round(v_dr, 2000, 10, 1500, 120);
  perform pg_temp.cr('T4a_ok','f', case when r.ok then 't' else 'f' end);
  perform pg_temp.cr('T4a_reason','not_authorized', coalesce(r.reason,''));
  perform pg_temp.cr('T4a_no_round','0', pg_temp.round_count(v_dr));
  -- reseta JWT -> system -> opened
  perform set_config('request.jwt.claims', '{}'::text, true);
  select * into r from public.open_dispatch_round(v_dr, 2000, 10, 1500, 120);
  perform pg_temp.cr('T4b_ok','t', case when r.ok then 't' else 'f' end);
  perform pg_temp.cr('T4b_reason','opened', coalesce(r.reason,''));
  perform pg_temp.cr('T4b_count','2', coalesce(r.candidate_count::text,''));
end $$;

-- ============================ T5: eligibility (radius 500 -> só dClose) ============================
-- Todos os outros drivers a ~111m estão dentro do raio 500 mas são excluídos por:
-- veículo incompatível (dCar), account_status (dSuspended), availability (dOffline/dBusy),
-- assignment ativa (dAssigned), localização velha (dStale), sem veículo (dNoVehicle).
do $$
declare r record;
  v_dr uuid := (select v from dp_ids where k='drElig');
  v_dClose uuid := (select v from dp_ids where k='dClose');
begin
  select * into r from public.open_dispatch_round(v_dr, 500, 10, 1500, 120);
  perform pg_temp.cr('T5_ok','t', case when r.ok then 't' else 'f' end);
  perform pg_temp.cr('T5_count','1', coalesce(r.candidate_count::text,''));
  perform pg_temp.cr('T5_only_dClose', v_dClose::text, pg_temp.offer_driver_ids(v_dr));
  perform pg_temp.cr('T5_offer_count','1', pg_temp.offer_count(v_dr));
end $$;

-- ============================ T6: max_candidates (radius 5000, limit 2 -> dClose+dMid) ============================
do $$
declare r record;
  v_dr uuid := (select v from dp_ids where k='drMax');
  v_dClose uuid := (select v from dp_ids where k='dClose');
  v_dMid uuid := (select v from dp_ids where k='dMid');
  v_dFar uuid := (select v from dp_ids where k='dFar');
begin
  select * into r from public.open_dispatch_round(v_dr, 5000, 2, 1500, 120);
  perform pg_temp.cr('T6_ok','t', case when r.ok then 't' else 'f' end);
  perform pg_temp.cr('T6_count','2', coalesce(r.candidate_count::text,''));
  -- só os 2 mais próximos (dClose ~111m, dMid ~1112m); dFar (~2224m) excluído pelo limit
  perform pg_temp.cr('T6_drivers',
    least(v_dClose::text,v_dMid::text)||','||greatest(v_dClose::text,v_dMid::text),
    pg_temp.offer_driver_ids(v_dr));
  perform pg_temp.cr('T6_dFar_excluded','0',
    (select count(*)::text from public.delivery_offers where delivery_request_id=v_dr and driver_id=v_dFar));
end $$;

-- ============================ T7: round_already_open (drRound já tem rodada aberta) ============================
do $$
declare r record;
  v_dr uuid := (select v from dp_ids where k='drRound');
begin
  select * into r from public.open_dispatch_round(v_dr, 2000, 10, 1500, 120);
  perform pg_temp.cr('T7_ok','f', case when r.ok then 't' else 'f' end);
  perform pg_temp.cr('T7_reason','round_already_open', coalesce(r.reason,''));
  perform pg_temp.cr('T7_still_one_open','1', pg_temp.open_round_count(v_dr));
end $$;

-- ============================ T8: raio progressivo (fechar round 1, abrir round 2 raio maior) ============================
do $$
declare r record;
  v_dr uuid := (select v from dp_ids where k='drRound');
  v_dMid uuid := (select v from dp_ids where k='dMid');
begin
  -- fecha round 1 (owner; simula Sessão 09 scoring/fechamento)
  update public.dispatch_rounds set status = 'closed'::public.dispatch_round_status,
         closed_at = now(), updated_at = now()
   where delivery_request_id = v_dr and status = 'open';
  -- round 2 com raio 5000 -> agora inclui dFar também (3 candidatos)
  select * into r from public.open_dispatch_round(v_dr, 5000, 10, 1500, 120);
  perform pg_temp.cr('T8_ok','t', case when r.ok then 't' else 'f' end);
  perform pg_temp.cr('T8_count','3', coalesce(r.candidate_count::text,''));
  -- round_number=2 (monotônico)
  perform pg_temp.cr('T8_round_number','2',
    (select round_number::text from public.dispatch_rounds where delivery_request_id=v_dr order by round_number desc limit 1));
  -- dMid (antes fora do raio 500 no round 1 implícito; agora dentro no round 2)
  perform pg_temp.cr('T8_dMid_in_round2','1',
    (select count(*)::text from public.delivery_offers o
      join public.dispatch_rounds r2 on r2.id=o.dispatch_round_id
      where o.delivery_request_id=v_dr and o.driver_id=v_dMid and r2.round_number=2));
  -- total de rounds = 2
  perform pg_temp.cr('T8_round_count','2', pg_temp.round_count(v_dr));
end $$;

-- ============================ T8b: wrong_state (quoted / assigned) ============================
do $$
declare r record;
  v_drQuoted uuid := (select v from dp_ids where k='drQuoted');
  v_drAsgn uuid := (select v from dp_ids where k='drAsgn');
begin
  -- drQuoted está 'quoted' (não confirmado) -> wrong_state
  select * into r from public.open_dispatch_round(v_drQuoted, 2000, 10, 1500, 120);
  perform pg_temp.cr('T8b_quoted_ok','f', case when r.ok then 't' else 'f' end);
  perform pg_temp.cr('T8b_quoted_reason','wrong_state', coalesce(r.reason,''));
  -- drAsgn está 'assigned' -> wrong_state
  select * into r from public.open_dispatch_round(v_drAsgn, 2000, 10, 1500, 120);
  perform pg_temp.cr('T8b_assigned_ok','f', case when r.ok then 't' else 'f' end);
  perform pg_temp.cr('T8b_assigned_reason','wrong_state', coalesce(r.reason,''));
  -- delivery não encontrada
  select * into r from public.open_dispatch_round(gen_random_uuid(), 2000, 10, 1500, 120);
  perform pg_temp.cr('T8b_notfound_reason','delivery_not_found', coalesce(r.reason,''));
end $$;

-- ============================ T9: 0 candidatos (radius 50) -> rodada criada, count=0 ============================
do $$
declare r record;
  v_dr uuid := (select v from dp_ids where k='drZero');
begin
  -- dClose está a ~111m (>50) -> 0 candidatos
  select * into r from public.open_dispatch_round(v_dr, 50, 10, 1500, 120);
  perform pg_temp.cr('T9_ok','t', case when r.ok then 't' else 'f' end);
  perform pg_temp.cr('T9_reason','opened', coalesce(r.reason,''));
  perform pg_temp.cr('T9_count','0', coalesce(r.candidate_count::text,''));
  perform pg_temp.cr('T9_round_created','1', pg_temp.round_count(v_dr));
  perform pg_temp.cr('T9_no_offers','0', pg_temp.offer_count(v_dr));
  -- ainda há evento round_opened (audit) mesmo com 0 candidatos
  perform pg_temp.cr('T9_ev_round_opened','t', pg_temp.has_event(v_dr,'round_opened'));
end $$;

-- ============================ T10: invalid_param ============================
do $$
declare r record;
  v_dr uuid := (select v from dp_ids where k='drRound');
begin
  select * into r from public.open_dispatch_round(v_dr, 0, 10, 1500, 120);    -- radius<=0
  perform pg_temp.cr('T10a_reason','invalid_param', coalesce(r.reason,''));
  select * into r from public.open_dispatch_round(v_dr, 2000, 0, 1500, 120);  -- max<=0
  perform pg_temp.cr('T10b_reason','invalid_param', coalesce(r.reason,''));
  select * into r from public.open_dispatch_round(v_dr, 2000, 10, 1500, 0);   -- window<=0
  perform pg_temp.cr('T10c_reason','invalid_param', coalesce(r.reason,''));
  select * into r from public.open_dispatch_round(v_dr, 2000, 10, -1, 120);   -- offer<0
  perform pg_temp.cr('T10d_reason','invalid_param', coalesce(r.reason,''));
end $$;

-- ============================ Resultado consolidado ============================
select
  (select count(*) from dp_results) as total,
  (select count(*) from dp_results where pass) as passed,
  (select count(*) from dp_results where not pass) as failed,
  (select string_agg(test, ', ') from dp_results where not pass) as failures;

rollback;