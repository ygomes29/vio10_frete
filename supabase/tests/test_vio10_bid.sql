-- test_vio10_bid.sql — Bid engine (Sessão 09, ADR-014).
-- Valida select_winner_and_claim (system-only): coleta candidatos validos (offers
-- respondidas + re-valida eligibility no close), pontua (bid_amount + ST_Distance,
-- normalizacao min-max, pesos de param, tie-break deterministico), escolhe vencedor,
-- chama claim_delivery atomico. Sem vencedor -> fecha rodada + no_candidates. ACEITAR !=
-- GANHAR.
--
-- Geometria: cada teste usa um pickup em (lat=0, lng=BASE) distinto (bases ~111km aparte
-- -> isolamento total via ST_DWithin; drivers de testes anteriores nao vazam). Drivers
-- do teste em (lat=0, lng=BASE+off). No equador 1 grau de longitude ~ 111320 m, logo:
--   off=0.001 -> ~111 m | off=0.01 -> ~1112 m | off=0.02 -> ~2224 m | off=0.045 -> ~5009 m
-- Para distancias iguais (T3/T13/T14), drivers no MESMO off.
--
-- Executa em begin/rollback (clean-slate). Tudo roda como owner (system path,
-- auth.uid()=null); testes user-scoped injetam sub via set_config. Resultados em bid_res.
-- Nota: now() e constante dentro de uma transacao -> responded_at igual para todas as
-- respostas no mesmo bloco; o tie-break por responded_at nao diferencia in-test (cai para
-- driver_id asc, o fallback deterministico). A ordem responded_at e exercitada em
-- concorrencia real na Sessao 10 (GATE).

set search_path to public, extensions;
begin;

create temp table bid_ids(k text primary key, v uuid);
create temp table bid_results(test text, expected text, actual text, pass boolean);

-- cr: registra expected vs actual em bid_results.
create or replace function pg_temp.cr(t text, exp text, act text) returns void
language plpgsql as $$
begin
  insert into bid_results(test, expected, actual, pass) values (t, exp, act, exp = act);
  if exp <> act then
    raise notice 'FAIL %: exp=% act=%', t, exp, act;
  end if;
end $$;

-- ============================ SETUP (owner path) ============================
-- orgA (membro uBU) + pricing rule orgA motorcycle. Drivers criados por teste.
do $$
declare v_orgA uuid; v_bizA uuid; v_uBU uuid;
begin
  insert into public.organizations(name) values('OrgA') returning id into v_orgA;
  insert into public.businesses(organization_id,name) values(v_orgA,'BizA') returning id into v_bizA;
  v_uBU := gen_random_uuid(); insert into auth.users(id,email) values(v_uBU,'bu@c.local');
  insert into public.organization_memberships(user_id,organization_id,role) values(v_uBU,v_orgA,'business_user');
  insert into public.pricing_rules
    (organization_id, vehicle_type, base_cents, per_km_cents, per_minute_cents,
     urgency_add_cents, min_price_cents, platform_fee_cents, is_active)
  values (v_orgA,'motorcycle',500,100,10,200,800,120,true);
  insert into bid_ids values ('orgA',v_orgA),('bizA',v_bizA),('uBU',v_uBU);
end $$;

-- mk_driver: cria auth.users(+profile via trigger) + driver motorcycle active available
-- fresh + veículo + localizacao em (lat=0, lng=p_lng). Retorna driver_id.
create or replace function pg_temp.mk_driver(
  p_email text, p_full text, p_phone text, p_lng double precision
) returns uuid
language plpgsql
set search_path = public, extensions, pg_catalog
as $$
declare v_uid uuid := gen_random_uuid(); v_did uuid; v_vid uuid;
begin
  insert into auth.users(id,email) values(v_uid, p_email);
  insert into public.drivers(user_id, full_name, phone, account_status, current_availability_status)
    values(v_uid, p_full, p_phone, 'active'::public.driver_account_status,
           'available'::public.driver_availability_status)
    returning id into v_did;
  insert into public.vehicles(driver_id, vehicle_type, plate)
    values(v_did, 'motorcycle'::public.vehicle_type, replace(p_full,' ','')||'-PLT')
    returning id into v_vid;
  update public.drivers set current_vehicle_id = v_vid where id = v_did;
  insert into public.driver_locations(driver_id, position, captured_at)
    values (v_did, st_setsrid(st_makepoint(p_lng, 0.0), 4326)::geography(Point,4326), now());
  return v_did;
end $$;

-- mk_draft: cria delivery_request em draft (system). pickup em (0, p_pickup_lng).
create or replace function pg_temp.mk_draft(p_org uuid, p_biz uuid, p_pickup_lng double precision) returns uuid
language plpgsql set search_path = public, extensions, pg_catalog
as $$
declare r record; v_items jsonb := '[{"description":"cx","quantity":1}]'::jsonb;
begin
  select * into r from public.create_delivery_request(
    p_org, p_biz, null,
    'Pickup', 0.0, p_pickup_lng, 'PN', '555', 'Delivery', 0.0, p_pickup_lng + 0.05, 'DN', '666',
    'motorcycle'::public.vehicle_type, 'standard'::public.delivery_priority,
    null, 'dashboard', null, null, null, v_items, null);
  return r.delivery_request_id;
end $$;

-- mk_searching: draft -> quoted (create_quote) -> confirm_quote -> searching_driver.
create or replace function pg_temp.mk_searching(p_org uuid, p_biz uuid, p_pickup_lng double precision) returns uuid
language plpgsql set search_path = public, extensions, pg_catalog
as $$
declare v_dr uuid; r record;
begin
  v_dr := pg_temp.mk_draft(p_org, p_biz, p_pickup_lng);
  select * into r from public.create_quote(v_dr, 10000, 600);
  select * into r from public.confirm_quote(v_dr);
  return v_dr;
end $$;

-- offer_of: id da offer de um driver num round.
create or replace function pg_temp.offer_of(p_round uuid, p_driver uuid) returns uuid
language sql security definer set search_path = public, pg_catalog
as $$ select id from public.delivery_offers where dispatch_round_id=p_round and driver_id=p_driver $$;

-- do_respond: responde uma offer (system path). Retorna ok.
create or replace function pg_temp.do_respond(
  p_offer uuid, p_driver uuid, p_rt text, p_amt bigint default null
) returns boolean
language plpgsql set search_path = public, pg_catalog
as $$
declare r record;
begin
  select * into r from public.respond_to_offer(p_offer, p_driver, p_rt::public.bid_response_type, p_amt);
  return r.ok;
end $$;

-- ============================ Helpers de inspeção (DEFINER, bypass RLS) ============================
create or replace function pg_temp.dr_status(p_id uuid) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select status::text from public.delivery_requests where id = p_id $$;
create or replace function pg_temp.round_status_of(p_round uuid) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select status::text from public.dispatch_rounds where id = p_round $$;
create or replace function pg_temp.round_closed_at_set(p_round uuid) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select case when closed_at is not null then 't' else 'f' end from public.dispatch_rounds where id = p_round $$;
create or replace function pg_temp.offer_status_of(p_offer uuid) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select status::text from public.delivery_offers where id = p_offer $$;
create or replace function pg_temp.active_assign_count(p_dr uuid) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select count(*)::text from public.delivery_assignments where delivery_request_id=p_dr and status='active' $$;
create or replace function pg_temp.active_assign_driver(p_dr uuid) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select driver_id::text from public.delivery_assignments where delivery_request_id=p_dr and status='active' limit 1 $$;
create or replace function pg_temp.has_event(p_dr uuid, p_ev text) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select case when exists(select 1 from public.delivery_events where delivery_request_id=p_dr and event_type=p_ev::public.delivery_event_type) then 't' else 'f' end $$;

-- ============================ T1: basic win (all accept, bids iguais -> mais proximo) ============================
do $$
declare r record;
  v_orgA uuid := (select v from bid_ids where k='orgA');
  v_bizA uuid := (select v from bid_ids where k='bizA');
  v_dr uuid; v_round uuid; B double precision := 1.0;
  v_d1 uuid; v_d2 uuid; v_d3 uuid; v_o1 uuid; v_o2 uuid; v_o3 uuid;
begin
  v_dr := pg_temp.mk_searching(v_orgA, v_bizA, B);
  v_d1 := pg_temp.mk_driver('t1d1@c.local','T1 D1','101', B+0.001);  -- ~111m
  v_d2 := pg_temp.mk_driver('t1d2@c.local','T1 D2','102', B+0.01);   -- ~1112m
  v_d3 := pg_temp.mk_driver('t1d3@c.local','T1 D3','103', B+0.02);   -- ~2224m
  select * into r from public.open_dispatch_round(v_dr, 5000, 10, 1500, 3600);
  v_round := r.round_id;
  v_o1 := pg_temp.offer_of(v_round, v_d1); v_o2 := pg_temp.offer_of(v_round, v_d2); v_o3 := pg_temp.offer_of(v_round, v_d3);
  perform pg_temp.do_respond(v_o1, v_d1, 'accept');
  perform pg_temp.do_respond(v_o2, v_d2, 'accept');
  perform pg_temp.do_respond(v_o3, v_d3, 'accept');
  -- todos accept -> bids iguais (1500) -> norm_bid 0 -> score so por distancia -> d1 (111m) vence
  select * into r from public.select_winner_and_claim(v_round, 1.0, 1.0);
  perform pg_temp.cr('T1_ok','t', case when r.ok then 't' else 'f' end);
  perform pg_temp.cr('T1_reason','won', coalesce(r.reason,''));
  perform pg_temp.cr('T1_winner', v_d1::text, coalesce(r.winner_driver_id::text,''));
  perform pg_temp.cr('T1_dr_status','assigned', pg_temp.dr_status(v_dr));
  perform pg_temp.cr('T1_offer_won','won', pg_temp.offer_status_of(v_o1));
  perform pg_temp.cr('T1_offer_lost2','lost', pg_temp.offer_status_of(v_o2));
  perform pg_temp.cr('T1_offer_lost3','lost', pg_temp.offer_status_of(v_o3));
  perform pg_temp.cr('T1_round_closed','closed', pg_temp.round_status_of(v_round));
  perform pg_temp.cr('T1_closed_at_set','t', pg_temp.round_closed_at_set(v_round));
  perform pg_temp.cr('T1_ev_winner_selected','t', pg_temp.has_event(v_dr,'winner_selected'));
  perform pg_temp.cr('T1_ev_driver_assigned','t', pg_temp.has_event(v_dr,'driver_assigned'));
  perform pg_temp.cr('T1_one_active','1', pg_temp.active_assign_count(v_dr));
  perform pg_temp.cr('T1_active_driver', v_d1::text, pg_temp.active_assign_driver(v_dr));
  insert into bid_ids values ('t1round', v_round);
end $$;

-- ============================ T2: no_candidates (decline + pending->expired) ============================
do $$
declare r record;
  v_orgA uuid := (select v from bid_ids where k='orgA');
  v_bizA uuid := (select v from bid_ids where k='bizA');
  v_dr uuid; v_round uuid; B double precision := 2.0;
  v_d1 uuid; v_d2 uuid; v_d3 uuid; v_o1 uuid; v_o2 uuid; v_o3 uuid;
begin
  v_dr := pg_temp.mk_searching(v_orgA, v_bizA, B);
  v_d1 := pg_temp.mk_driver('t2d1@c.local','T2 D1','201', B+0.001);
  v_d2 := pg_temp.mk_driver('t2d2@c.local','T2 D2','202', B+0.01);
  v_d3 := pg_temp.mk_driver('t2d3@c.local','T2 D3','203', B+0.02);
  select * into r from public.open_dispatch_round(v_dr, 5000, 10, 1500, 3600);
  v_round := r.round_id;
  v_o1 := pg_temp.offer_of(v_round, v_d1); v_o2 := pg_temp.offer_of(v_round, v_d2); v_o3 := pg_temp.offer_of(v_round, v_d3);
  perform pg_temp.do_respond(v_o1, v_d1, 'decline');
  perform pg_temp.do_respond(v_o2, v_d2, 'decline');
  -- d3 nao responde -> pending
  select * into r from public.select_winner_and_claim(v_round, 1.0, 1.0);
  perform pg_temp.cr('T2_ok','t', case when r.ok then 't' else 'f' end);
  perform pg_temp.cr('T2_reason','no_candidates', coalesce(r.reason,''));
  perform pg_temp.cr('T2_no_winner','t', case when r.winner_driver_id is null then 't' else 'f' end);
  perform pg_temp.cr('T2_dr_still_searching','searching_driver', pg_temp.dr_status(v_dr));
  perform pg_temp.cr('T2_round_closed','closed', pg_temp.round_status_of(v_round));
  perform pg_temp.cr('T2_d3_pending_expired','expired', pg_temp.offer_status_of(v_o3));
  perform pg_temp.cr('T2_d1_still_declined','declined', pg_temp.offer_status_of(v_o1));
  perform pg_temp.cr('T2_ev_round_closed','t', pg_temp.has_event(v_dr,'round_closed'));
  perform pg_temp.cr('T2_no_assignment','0', pg_temp.active_assign_count(v_dr));
  insert into bid_ids values ('t2dr', v_dr);
end $$;

-- ============================ T3: counter_bid (distancias iguais -> menor bid vence) ============================
do $$
declare r record;
  v_orgA uuid := (select v from bid_ids where k='orgA');
  v_bizA uuid := (select v from bid_ids where k='bizA');
  v_dr uuid; v_round uuid; B double precision := 3.0;
  v_d1 uuid; v_d2 uuid; v_d3 uuid; v_o1 uuid; v_o2 uuid; v_o3 uuid;
begin
  v_dr := pg_temp.mk_searching(v_orgA, v_bizA, B);
  -- todos no mesmo off=0.001 (~111m) -> distancias iguais -> norm_dist 0 -> score so por bid
  v_d1 := pg_temp.mk_driver('t3d1@c.local','T3 D1','301', B+0.001);
  v_d2 := pg_temp.mk_driver('t3d2@c.local','T3 D2','302', B+0.001);
  v_d3 := pg_temp.mk_driver('t3d3@c.local','T3 D3','303', B+0.001);
  select * into r from public.open_dispatch_round(v_dr, 5000, 10, 1500, 3600);
  v_round := r.round_id;
  v_o1 := pg_temp.offer_of(v_round, v_d1); v_o2 := pg_temp.offer_of(v_round, v_d2); v_o3 := pg_temp.offer_of(v_round, v_d3);
  perform pg_temp.do_respond(v_o1, v_d1, 'accept');                 -- bid=1500 (driver_offer_cents)
  perform pg_temp.do_respond(v_o2, v_d2, 'counter_bid', 950);       -- bid=950 (menor)
  perform pg_temp.do_respond(v_o3, v_d3, 'counter_bid', 1100);      -- bid=1100
  select * into r from public.select_winner_and_claim(v_round, 1.0, 1.0);
  perform pg_temp.cr('T3_ok','t', case when r.ok then 't' else 'f' end);
  perform pg_temp.cr('T3_winner_lowest_bid', v_d2::text, coalesce(r.winner_driver_id::text,''));
  perform pg_temp.cr('T3_dr_status','assigned', pg_temp.dr_status(v_dr));
end $$;

-- ============================ T4: weight_price=0 (mais proximo vence independente do bid) ============================
do $$
declare r record;
  v_orgA uuid := (select v from bid_ids where k='orgA');
  v_bizA uuid := (select v from bid_ids where k='bizA');
  v_dr uuid; v_round uuid; B double precision := 4.0;
  v_d1 uuid; v_d2 uuid; v_o1 uuid; v_o2 uuid;
begin
  v_dr := pg_temp.mk_searching(v_orgA, v_bizA, B);
  v_d1 := pg_temp.mk_driver('t4d1@c.local','T4 D1','401', B+0.001);  -- ~111m, bid alto
  v_d2 := pg_temp.mk_driver('t4d2@c.local','T4 D2','402', B+0.01);   -- ~1112m, bid baixo
  select * into r from public.open_dispatch_round(v_dr, 5000, 10, 1500, 3600);
  v_round := r.round_id;
  v_o1 := pg_temp.offer_of(v_round, v_d1); v_o2 := pg_temp.offer_of(v_round, v_d2);
  perform pg_temp.do_respond(v_o1, v_d1, 'counter_bid', 1500);  -- d1: perto, bid 1500
  perform pg_temp.do_respond(v_o2, v_d2, 'counter_bid', 950);    -- d2: longe, bid 950
  -- weight_price=0 -> ignora bid -> d1 (111m) vence apesar do bid maior
  select * into r from public.select_winner_and_claim(v_round, 0.0, 1.0);
  perform pg_temp.cr('T4_ok','t', case when r.ok then 't' else 'f' end);
  perform pg_temp.cr('T4_winner_closest', v_d1::text, coalesce(r.winner_driver_id::text,''));
end $$;

-- ============================ T5: weight sensitivity (1/1 -> d2 ; 2/1 -> d3) ============================
-- d1(111m,bid1500) d2(1112m,bid1400) d3(2224m,bid1300). 1/1: d2 vence. 2/1: d3 vence.
do $$
declare r record;
  v_orgA uuid := (select v from bid_ids where k='orgA');
  v_bizA uuid := (select v from bid_ids where k='bizA');
  v_dr1 uuid; v_dr2 uuid; v_round1 uuid; v_round2 uuid;
  v_a1 uuid; v_a2 uuid; v_a3 uuid; v_b1 uuid; v_b2 uuid; v_b3 uuid;
begin
  -- cenario A (base 5.0): pesos 1/1 -> d2 (balance)
  v_dr1 := pg_temp.mk_searching(v_orgA, v_bizA, 5.0);
  v_a1 := pg_temp.mk_driver('t5a1@c.local','T5 A1','501', 5.001);
  v_a2 := pg_temp.mk_driver('t5a2@c.local','T5 A2','502', 5.01);
  v_a3 := pg_temp.mk_driver('t5a3@c.local','T5 A3','503', 5.02);
  select * into r from public.open_dispatch_round(v_dr1, 5000, 10, 1500, 3600); v_round1 := r.round_id;
  perform pg_temp.do_respond(pg_temp.offer_of(v_round1,v_a1), v_a1, 'counter_bid', 1500);
  perform pg_temp.do_respond(pg_temp.offer_of(v_round1,v_a2), v_a2, 'counter_bid', 1400);
  perform pg_temp.do_respond(pg_temp.offer_of(v_round1,v_a3), v_a3, 'counter_bid', 1300);
  select * into r from public.select_winner_and_claim(v_round1, 1.0, 1.0);
  perform pg_temp.cr('T5a_winner_equal_weights', v_a2::text, coalesce(r.winner_driver_id::text,''));

  -- cenario B (base 6.0): mesmas posicoes/bids, pesos 2/1 -> d3 (bid pesa mais -> menor bid vence)
  v_dr2 := pg_temp.mk_searching(v_orgA, v_bizA, 6.0);
  v_b1 := pg_temp.mk_driver('t5b1@c.local','T5 B1','511', 6.001);
  v_b2 := pg_temp.mk_driver('t5b2@c.local','T5 B2','512', 6.01);
  v_b3 := pg_temp.mk_driver('t5b3@c.local','T5 B3','513', 6.02);
  select * into r from public.open_dispatch_round(v_dr2, 5000, 10, 1500, 3600); v_round2 := r.round_id;
  perform pg_temp.do_respond(pg_temp.offer_of(v_round2,v_b1), v_b1, 'counter_bid', 1500);
  perform pg_temp.do_respond(pg_temp.offer_of(v_round2,v_b2), v_b2, 'counter_bid', 1400);
  perform pg_temp.do_respond(pg_temp.offer_of(v_round2,v_b3), v_b3, 'counter_bid', 1300);
  select * into r from public.select_winner_and_claim(v_round2, 2.0, 1.0);
  perform pg_temp.cr('T5b_winner_price_heavy', v_b3::text, coalesce(r.winner_driver_id::text,''));
end $$;

-- ============================ T6: eligibility re-check (assignment race -> proximo vence) ============================
do $$
declare r record;
  v_orgA uuid := (select v from bid_ids where k='orgA');
  v_bizA uuid := (select v from bid_ids where k='bizA');
  v_dr uuid; v_dr_other uuid; v_round uuid; B double precision := 7.0;
  v_d1 uuid; v_d2 uuid; v_o1 uuid; v_o2 uuid;
begin
  v_dr := pg_temp.mk_searching(v_orgA, v_bizA, B);
  v_dr_other := pg_temp.mk_searching(v_orgA, v_bizA, 7.5);  -- outra corrida (base isolada)
  v_d1 := pg_temp.mk_driver('t6d1@c.local','T6 D1','601', B+0.001);  -- ~111m (vencedor esperado)
  v_d2 := pg_temp.mk_driver('t6d2@c.local','T6 D2','602', B+0.01);   -- ~1112m
  select * into r from public.open_dispatch_round(v_dr, 5000, 10, 1500, 3600); v_round := r.round_id;
  v_o1 := pg_temp.offer_of(v_round, v_d1); v_o2 := pg_temp.offer_of(v_round, v_d2);
  perform pg_temp.do_respond(v_o1, v_d1, 'accept');
  perform pg_temp.do_respond(v_o2, v_d2, 'accept');
  -- d1 ganha assignment ativa em OUTRA corrida antes do close -> excluido
  insert into public.delivery_assignments(delivery_request_id, driver_id, status)
    values (v_dr_other, v_d1, 'active');
  select * into r from public.select_winner_and_claim(v_round, 1.0, 1.0);
  perform pg_temp.cr('T6_ok','t', case when r.ok then 't' else 'f' end);
  perform pg_temp.cr('T6_d1_excluded_next_best', v_d2::text, coalesce(r.winner_driver_id::text,''));
  perform pg_temp.cr('T6_offer_d1_lost','lost', pg_temp.offer_status_of(v_o1));
end $$;

-- ============================ T7: eligibility re-check (offline -> excluido) ============================
do $$
declare r record;
  v_orgA uuid := (select v from bid_ids where k='orgA');
  v_bizA uuid := (select v from bid_ids where k='bizA');
  v_dr uuid; v_round uuid; B double precision := 8.0;
  v_d1 uuid; v_d2 uuid; v_o1 uuid; v_o2 uuid;
begin
  v_dr := pg_temp.mk_searching(v_orgA, v_bizA, B);
  v_d1 := pg_temp.mk_driver('t7d1@c.local','T7 D1','701', B+0.001);
  v_d2 := pg_temp.mk_driver('t7d2@c.local','T7 D2','702', B+0.01);
  select * into r from public.open_dispatch_round(v_dr, 5000, 10, 1500, 3600); v_round := r.round_id;
  v_o1 := pg_temp.offer_of(v_round, v_d1); v_o2 := pg_temp.offer_of(v_round, v_d2);
  perform pg_temp.do_respond(v_o1, v_d1, 'accept');
  perform pg_temp.do_respond(v_o2, v_d2, 'accept');
  -- d1 vai offline antes do close -> excluido
  update public.drivers set current_availability_status = 'offline'::public.driver_availability_status
    where id = v_d1;
  select * into r from public.select_winner_and_claim(v_round, 1.0, 1.0);
  perform pg_temp.cr('T7_ok','t', case when r.ok then 't' else 'f' end);
  perform pg_temp.cr('T7_d1_offline_next_best', v_d2::text, coalesce(r.winner_driver_id::text,''));
end $$;

-- ============================ T8: expired offer excluded ============================
do $$
declare r record;
  v_orgA uuid := (select v from bid_ids where k='orgA');
  v_bizA uuid := (select v from bid_ids where k='bizA');
  v_dr uuid; v_round uuid; B double precision := 9.0;
  v_d1 uuid; v_d2 uuid; v_o1 uuid; v_o2 uuid;
begin
  v_dr := pg_temp.mk_searching(v_orgA, v_bizA, B);
  v_d1 := pg_temp.mk_driver('t8d1@c.local','T8 D1','801', B+0.001);
  v_d2 := pg_temp.mk_driver('t8d2@c.local','T8 D2','802', B+0.01);
  select * into r from public.open_dispatch_round(v_dr, 5000, 10, 1500, 3600); v_round := r.round_id;
  v_o1 := pg_temp.offer_of(v_round, v_d1); v_o2 := pg_temp.offer_of(v_round, v_d2);
  perform pg_temp.do_respond(v_o1, v_d1, 'accept');
  perform pg_temp.do_respond(v_o2, v_d2, 'accept');
  -- offer de d1 expirada antes do close -> excluida do scoring
  update public.delivery_offers set expires_at = now() - interval '1 second' where id = v_o1;
  select * into r from public.select_winner_and_claim(v_round, 1.0, 1.0);
  perform pg_temp.cr('T8_ok','t', case when r.ok then 't' else 'f' end);
  perform pg_temp.cr('T8_d1_expired_next_best', v_d2::text, coalesce(r.winner_driver_id::text,''));
end $$;

-- ============================ T9: round_already_closed -> round_not_open ============================
do $$
declare r record; v_round uuid := (select v from bid_ids where k='t1round');
begin
  -- rodada do T1 ja foi fechada pelo claim
  select * into r from public.select_winner_and_claim(v_round, 1.0, 1.0);
  perform pg_temp.cr('T9_ok','f', case when r.ok then 't' else 'f' end);
  perform pg_temp.cr('T9_reason','round_not_open', coalesce(r.reason,''));
end $$;

-- ============================ T10: wrong_state (delivery cancelada) ============================
do $$
declare r record;
  v_orgA uuid := (select v from bid_ids where k='orgA');
  v_bizA uuid := (select v from bid_ids where k='bizA');
  v_dr uuid; v_round uuid; v_d1 uuid; B double precision := 10.0;
begin
  v_dr := pg_temp.mk_searching(v_orgA, v_bizA, B);
  v_d1 := pg_temp.mk_driver('t10d1@c.local','T10 D1','1001', B+0.001);
  select * into r from public.open_dispatch_round(v_dr, 5000, 10, 1500, 3600); v_round := r.round_id;
  perform pg_temp.do_respond(pg_temp.offer_of(v_round, v_d1), v_d1, 'accept');
  -- delivery cancelada (owner) antes do close
  update public.delivery_requests set status = 'cancelled'::public.delivery_status where id = v_dr;
  select * into r from public.select_winner_and_claim(v_round, 1.0, 1.0);
  perform pg_temp.cr('T10_ok','f', case when r.ok then 't' else 'f' end);
  perform pg_temp.cr('T10_reason','wrong_state', coalesce(r.reason,''));
end $$;

-- ============================ T11: system-only (not_authorized; system ok) ============================
do $$
declare r record;
  v_orgA uuid := (select v from bid_ids where k='orgA');
  v_bizA uuid := (select v from bid_ids where k='bizA');
  v_dr uuid; v_round uuid; v_d1 uuid; v_fake uuid := gen_random_uuid(); B double precision := 11.0;
begin
  v_dr := pg_temp.mk_searching(v_orgA, v_bizA, B);
  v_d1 := pg_temp.mk_driver('t11d1@c.local','T11 D1','1101', B+0.001);
  select * into r from public.open_dispatch_round(v_dr, 5000, 10, 1500, 3600); v_round := r.round_id;
  perform pg_temp.do_respond(pg_temp.offer_of(v_round, v_d1), v_d1, 'accept');
  -- caller autenticado (sub falso) -> not_authorized
  perform set_config('request.jwt.claims', json_build_object('sub',v_fake)::text, true);
  select * into r from public.select_winner_and_claim(v_round, 1.0, 1.0);
  perform pg_temp.cr('T11a_ok','f', case when r.ok then 't' else 'f' end);
  perform pg_temp.cr('T11a_reason','not_authorized', coalesce(r.reason,''));
  -- reseta JWT -> system -> won
  perform set_config('request.jwt.claims', '{}'::text, true);
  select * into r from public.select_winner_and_claim(v_round, 1.0, 1.0);
  perform pg_temp.cr('T11b_ok','t', case when r.ok then 't' else 'f' end);
  perform pg_temp.cr('T11b_reason','won', coalesce(r.reason,''));
end $$;

-- ============================ T12: invalid_param ============================
do $$
declare r record;
  v_orgA uuid := (select v from bid_ids where k='orgA');
  v_bizA uuid := (select v from bid_ids where k='bizA');
  v_dr uuid; v_round uuid; v_d1 uuid; B double precision := 12.0;
begin
  v_dr := pg_temp.mk_searching(v_orgA, v_bizA, B);
  v_d1 := pg_temp.mk_driver('t12d1@c.local','T12 D1','1201', B+0.001);
  select * into r from public.open_dispatch_round(v_dr, 5000, 10, 1500, 3600); v_round := r.round_id;
  perform pg_temp.do_respond(pg_temp.offer_of(v_round, v_d1), v_d1, 'accept');
  select * into r from public.select_winner_and_claim(v_round, 0.0, 0.0);            -- ambos pesos 0
  perform pg_temp.cr('T12a_reason','invalid_param', coalesce(r.reason,''));
  select * into r from public.select_winner_and_claim(v_round, -1.0, 1.0);          -- peso negativo
  perform pg_temp.cr('T12b_reason','invalid_param', coalesce(r.reason,''));
  select * into r from public.select_winner_and_claim(v_round, 1.0, 1.0, 0);         -- max_age<=0
  perform pg_temp.cr('T12c_reason','invalid_param', coalesce(r.reason,''));
  -- round ainda aberta (param falhou antes de fechar)
  perform pg_temp.cr('T12d_round_still_open','open', pg_temp.round_status_of(v_round));
end $$;

-- ============================ T13: tie-break (bid+dist iguais -> driver_id asc) ============================
do $$
declare r record;
  v_orgA uuid := (select v from bid_ids where k='orgA');
  v_bizA uuid := (select v from bid_ids where k='bizA');
  v_dr uuid; v_round uuid; v_d1 uuid; v_d2 uuid; v_o1 uuid; v_o2 uuid; B double precision := 13.0;
  v_min text;
begin
  v_dr := pg_temp.mk_searching(v_orgA, v_bizA, B);
  -- ambos no mesmo off=0.001 (mesma dist) + ambos accept (mesmo bid) -> score identico.
  -- responded_at igual (mesma tx/now()) -> tie-break final: driver_id asc.
  v_d1 := pg_temp.mk_driver('t13d1@c.local','T13 D1','1301', B+0.001);
  v_d2 := pg_temp.mk_driver('t13d2@c.local','T13 D2','1302', B+0.001);
  select * into r from public.open_dispatch_round(v_dr, 5000, 10, 1500, 3600); v_round := r.round_id;
  v_o1 := pg_temp.offer_of(v_round, v_d1); v_o2 := pg_temp.offer_of(v_round, v_d2);
  perform pg_temp.do_respond(v_o1, v_d1, 'accept');
  perform pg_temp.do_respond(v_o2, v_d2, 'accept');
  select * into r from public.select_winner_and_claim(v_round, 1.0, 1.0);
  -- vencedor = menor driver_id (deterministico, estavel entre runs)
  v_min := least(v_d1::text, v_d2::text);
  perform pg_temp.cr('T13_winner_smaller_driver_id', v_min, coalesce(r.winner_driver_id::text,''));
  perform pg_temp.cr('T13_ok','t', case when r.ok then 't' else 'f' end);
end $$;

-- ============================ T14: fator constante (distancias iguais -> bid decide; nullif) ============================
do $$
declare r record;
  v_orgA uuid := (select v from bid_ids where k='orgA');
  v_bizA uuid := (select v from bid_ids where k='bizA');
  v_dr uuid; v_round uuid; B double precision := 14.0;
  v_d1 uuid; v_d2 uuid; v_d3 uuid;
begin
  v_dr := pg_temp.mk_searching(v_orgA, v_bizA, B);
  -- todos no mesmo off (dist igual) -> norm_dist 0 p/ todos (nullif) -> score so por bid
  v_d1 := pg_temp.mk_driver('t14d1@c.local','T14 D1','1401', B+0.001);
  v_d2 := pg_temp.mk_driver('t14d2@c.local','T14 D2','1402', B+0.001);
  v_d3 := pg_temp.mk_driver('t14d3@c.local','T14 D3','1403', B+0.001);
  select * into r from public.open_dispatch_round(v_dr, 5000, 10, 1500, 3600); v_round := r.round_id;
  perform pg_temp.do_respond(pg_temp.offer_of(v_round,v_d1), v_d1, 'counter_bid', 1500);
  perform pg_temp.do_respond(pg_temp.offer_of(v_round,v_d2), v_d2, 'counter_bid', 1000);  -- menor
  perform pg_temp.do_respond(pg_temp.offer_of(v_round,v_d3), v_d3, 'counter_bid', 1200);
  select * into r from public.select_winner_and_claim(v_round, 1.0, 1.0);
  perform pg_temp.cr('T14_winner_lowest_bid', v_d2::text, coalesce(r.winner_driver_id::text,''));
  perform pg_temp.cr('T14_ok','t', case when r.ok then 't' else 'f' end);
end $$;

-- ============================ T15: raio progressivo (no_candidates round1 -> round2 raio maior -> win) ============================
do $$
declare r record;
  v_orgA uuid := (select v from bid_ids where k='orgA');
  v_bizA uuid := (select v from bid_ids where k='bizA');
  v_dr uuid; v_round1 uuid; v_round2 uuid; B double precision := 15.0;
  v_d1 uuid; v_d2 uuid; v_o1 uuid; v_o2 uuid;
begin
  v_dr := pg_temp.mk_searching(v_orgA, v_bizA, B);
  v_d1 := pg_temp.mk_driver('t15d1@c.local','T15 D1','1501', B+0.001);  -- ~111m
  v_d2 := pg_temp.mk_driver('t15d2@c.local','T15 D2','1502', B+0.045);  -- ~5009m
  -- round 1: raio 2000 -> so d1 (111m) candidato; d1 decline -> no_candidates, round1 closed
  select * into r from public.open_dispatch_round(v_dr, 2000, 10, 1500, 3600); v_round1 := r.round_id;
  perform pg_temp.cr('T15_round1_count','1', coalesce(r.candidate_count::text,''));
  v_o1 := pg_temp.offer_of(v_round1, v_d1);
  perform pg_temp.do_respond(v_o1, v_d1, 'decline');
  select * into r from public.select_winner_and_claim(v_round1, 1.0, 1.0);
  perform pg_temp.cr('T15_round1_no_candidates','no_candidates', coalesce(r.reason,''));
  perform pg_temp.cr('T15_round1_closed','closed', pg_temp.round_status_of(v_round1));
  -- round 2: raio 6000 -> d1(111m)+d2(5009m) candidatos; d1 tem nova offer na round2
  select * into r from public.open_dispatch_round(v_dr, 6000, 10, 1500, 3600); v_round2 := r.round_id;
  perform pg_temp.cr('T15_round2_count','2', coalesce(r.candidate_count::text,''));
  perform pg_temp.cr('T15_round2_number','2',
    (select round_number::text from public.dispatch_rounds where id = v_round2));
  v_o1 := pg_temp.offer_of(v_round2, v_d1); v_o2 := pg_temp.offer_of(v_round2, v_d2);
  perform pg_temp.do_respond(v_o1, v_d1, 'accept');
  perform pg_temp.do_respond(v_o2, v_d2, 'accept');
  select * into r from public.select_winner_and_claim(v_round2, 1.0, 1.0);
  perform pg_temp.cr('T15_round2_winner_closest', v_d1::text, coalesce(r.winner_driver_id::text,''));
  perform pg_temp.cr('T15_dr_assigned','assigned', pg_temp.dr_status(v_dr));
end $$;

-- ============================ T16: not_found (round_id inexistente) ============================
do $$
declare r record;
begin
  select * into r from public.select_winner_and_claim(gen_random_uuid(), 1.0, 1.0);
  perform pg_temp.cr('T16_ok','f', case when r.ok then 't' else 'f' end);
  perform pg_temp.cr('T16_reason','not_found', coalesce(r.reason,''));
end $$;

-- ============================ Resultado consolidado ============================
select
  (select count(*) from bid_results) as total,
  (select count(*) from bid_results where pass) as passed,
  (select count(*) from bid_results where not pass) as failed,
  (select string_agg(test, ', ') from bid_results where not pass) as failures;

rollback;