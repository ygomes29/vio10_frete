-- test_vio10_lifecycle.sql — Ciclo completo pós-assigned + POD gate (Sessão 11, ADR-016).
-- Valida a máquina de estados refinada: matriz ator×transição (D1), limite de reatribuição
-- via metadata (D2), cancelled/failed reason (D3), POD two-phase submit/confirm (D4),
-- POD gate em delivered (D5), completude do POD (D6). Submeter POD != entregue (análogo a
-- ACEITAR != GANHAR).
--
-- Geometria: cada teste usa pickup em (lat=0, lng=BASE) distinto (bases ~111km aparte ->
-- isolamento total via ST_DWithin; drivers de testes anteriores não vazam para
-- open_dispatch_round). Drivers do teste em (lat=0, lng=BASE+off).
--
-- Executa em begin/rollback (clean-slate). Setup como owner (system path, auth.uid()=null).
--
-- DISCIPLINA DE JWT (lição Sessão 06): set_config('request.jwt.claims',...,true) é
-- is_local — persiste até o fim da TRANSAÇÃO, não do bloco. O residual do bloco anterior
-- vaza para o próximo se não for re-setado. Logo CADA bloco:
--   1. reseta para '{}' (system) ANTES de qualquer mk_*/create_/confirm_quote (system path);
--   2. seta o ator (driver/admin/business) ANTES das chamadas autenticadas;
--   3. reseta de volta para '{}' antes de chamadas system-only dentro do mesmo bloco.
-- RPCs chamadas DIRETAMENTE no bloco (não via helper) — auth.uid() lê o GUC setado.
--
-- pgTAP: num_failed()=0 é a autoridade (finish() emite 0 rows neste dev — Sessão 08).
-- Resultados consolidados num único SELECT final em lc_results.

set search_path to public, extensions;
begin;

create temp table lc_ids(k text primary key, v uuid);
create temp table lc_map(dr_id uuid primary key, driver_id uuid);
create temp table lc_results(test text, expected text, actual text, pass boolean);

-- cr: registra expected vs actual em lc_results.
create or replace function pg_temp.cr(t text, exp text, act text) returns void
language plpgsql as $$
begin
  insert into lc_results(test, expected, actual, pass) values (t, exp, act, exp = act);
  if exp <> act then
    raise notice 'FAIL %: exp=% act=%', t, exp, act;
  end if;
end $$;

-- ============================ SETUP (owner path, system) ============================
-- orgA + bizA + uBU (membro org business) + uAd (platform operator = classe admin em D1)
-- + pricing rule orgA motorcycle.
do $$
declare v_orgA uuid; v_bizA uuid; v_uBU uuid; v_uAd uuid;
begin
  perform set_config('request.jwt.claims', '{}'::text, true);
  insert into public.organizations(name) values('OrgA') returning id into v_orgA;
  insert into public.businesses(organization_id,name) values(v_orgA,'BizA') returning id into v_bizA;
  v_uBU := gen_random_uuid(); insert into auth.users(id,email) values(v_uBU,'bu@c.local');
  insert into public.organization_memberships(user_id,organization_id,role) values(v_uBU,v_orgA,'business_user');
  v_uAd := gen_random_uuid(); insert into auth.users(id,email) values(v_uAd,'ad@c.local');
  -- profile criado pelo trigger handle_new_user (0018) ao inserir auth.users.
  insert into public.user_platform_roles(user_id, role) values(v_uAd,'operator');
  insert into public.pricing_rules
    (organization_id, vehicle_type, base_cents, per_km_cents, per_minute_cents,
     urgency_add_cents, min_price_cents, platform_fee_cents, is_active)
  values (v_orgA,'motorcycle',500,100,10,200,800,120,true);
  insert into lc_ids values ('orgA',v_orgA),('bizA',v_bizA),('uBU',v_uBU),('uAd',v_uAd);
end $$;

-- mk_driver: auth.users(+profile via trigger) + driver motorcycle active available fresh
-- + veículo + localizacao em (lat=0, lng=p_lng). Retorna driver_id.
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

-- mk_draft: delivery_request em draft (system). pickup em (0, p_pickup_lng).
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

-- mk_assigned: leva uma corrida a `assigned` com driver atribuído (active assignment).
-- Cria driver em p_pickup_lng+0.001 (~111m < raio 5000m), abre rodada, accept, claim_delivery.
-- Armazena driver_id em lc_map. Retorna delivery_request_id. Requer system path (caller resetou JWT).
create or replace function pg_temp.mk_assigned(p_org uuid, p_biz uuid, p_pickup_lng double precision) returns uuid
language plpgsql set search_path = public, extensions, pg_catalog
as $$
declare v_dr uuid; v_did uuid; r record; v_round uuid; v_offer uuid;
begin
  v_dr := pg_temp.mk_searching(p_org, p_biz, p_pickup_lng);
  v_did := pg_temp.mk_driver('drv_'||p_pickup_lng::text||'@c.local', 'Drv '||p_pickup_lng::text, '5', p_pickup_lng + 0.001);
  select * into r from public.open_dispatch_round(v_dr, 5000, 10, 1500, 3600);
  v_round := r.round_id;
  v_offer := pg_temp.offer_of(v_round, v_did);
  perform pg_temp.do_respond(v_offer, v_did, 'accept');
  select * into r from public.claim_delivery(v_dr, v_did, v_round, v_offer, null, null);
  insert into lc_map(dr_id, driver_id) values (v_dr, v_did);
  return v_dr;
end $$;

-- ============================ Helpers de inspeção (DEFINER, bypass RLS) ============================
create or replace function pg_temp.dr_status(p_id uuid) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select status::text from public.delivery_requests where id = p_id $$;
create or replace function pg_temp.active_assign_count(p_dr uuid) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select count(*)::text from public.delivery_assignments where delivery_request_id=p_dr and status='active' $$;
create or replace function pg_temp.active_assign_driver(p_dr uuid) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select driver_id::text from public.delivery_assignments where delivery_request_id=p_dr and status='active' limit 1 $$;
create or replace function pg_temp.assign_ended_reason(p_dr uuid) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select ended_reason from public.delivery_assignments where delivery_request_id=p_dr and status='superseded' order by ended_at desc limit 1 $$;
create or replace function pg_temp.has_event(p_dr uuid, p_ev text) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select case when exists(select 1 from public.delivery_events where delivery_request_id=p_dr and event_type=p_ev::public.delivery_event_type) then 't' else 'f' end $$;
create or replace function pg_temp.event_actor_of(p_dr uuid, p_ev text) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select actor_type from public.delivery_events where delivery_request_id=p_dr and event_type=p_ev::public.delivery_event_type order by created_at desc, id desc limit 1 $$;
create or replace function pg_temp.reassign_count_of(p_dr uuid) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select coalesce(reassignment_count::text,'0') from public.delivery_requests where id = p_dr $$;
create or replace function pg_temp.cancelled_reason_of(p_dr uuid) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select coalesce(cancelled_reason,'') from public.delivery_requests where id = p_dr $$;
create or replace function pg_temp.failed_reason_of(p_dr uuid) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select coalesce(failed_reason,'') from public.delivery_requests where id = p_dr $$;
create or replace function pg_temp.pod_exists(p_dr uuid, p_pt text) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select case when exists(select 1 from public.proof_of_delivery where delivery_request_id=p_dr and pod_type=p_pt::public.pod_type) then 't' else 'f' end $$;
create or replace function pg_temp.delivered_at_set(p_dr uuid) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select case when delivered_at is not null then 't' else 'f' end from public.delivery_requests where id = p_dr $$;
-- drv_user: auth.users id (sub) de um driver — para set_config.
create or replace function pg_temp.drv_user(p_driver uuid) returns uuid
language sql security definer set search_path = public, pg_catalog
as $$ select user_id from public.drivers where id = p_driver $$;
create or replace function pg_temp.lc_driver(p_dr uuid) returns uuid
language sql security definer set search_path = public, pg_catalog
as $$ select driver_id from lc_map where dr_id = p_dr $$;

-- ============================ T1: happy path driver (assigned -> in_transit) ============================
do $$
declare r record; v_dr uuid; v_d uuid; v_org uuid; v_biz uuid;
begin
  select v into v_org from lc_ids where k='orgA'; select v into v_biz from lc_ids where k='bizA';
  perform set_config('request.jwt.claims', '{}'::text, true);  -- system: mk_assigned
  v_dr := pg_temp.mk_assigned(v_org, v_biz, 1.0);
  v_d  := pg_temp.lc_driver(v_dr);
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.drv_user(v_d))::text, true);  -- driver
  select * into r from public.transition_delivery(v_dr, 'driver_to_pickup');
  perform pg_temp.cr('T1a_d2p','transitioned', r.reason);
  select * into r from public.transition_delivery(v_dr, 'at_pickup');
  perform pg_temp.cr('T1b_atp','transitioned', r.reason);
  -- Sessão 12 (ADR-017 D3): picked_up exige pickup POD (gate).
  insert into public.proof_of_delivery(delivery_request_id, pod_type, storage_path)
    values (v_dr, 'pickup'::public.pod_type, 'pod/p.jpg');
  select * into r from public.transition_delivery(v_dr, 'picked_up');
  perform pg_temp.cr('T1c_pku','transitioned', r.reason);
  select * into r from public.transition_delivery(v_dr, 'in_transit');
  perform pg_temp.cr('T1d_itr','transitioned', r.reason);
  perform pg_temp.cr('T1_status','in_transit', pg_temp.dr_status(v_dr));
  perform pg_temp.cr('T1_ev_d2p','t', pg_temp.has_event(v_dr,'driver_to_pickup'));
  perform pg_temp.cr('T1_ev_atp','t', pg_temp.has_event(v_dr,'arrived_at_pickup'));
  perform pg_temp.cr('T1_ev_pku','t', pg_temp.has_event(v_dr,'picked_up'));
  perform pg_temp.cr('T1_ev_itr','t', pg_temp.has_event(v_dr,'in_transit'));
  perform pg_temp.cr('T1_actor','driver', pg_temp.event_actor_of(v_dr,'in_transit'));
end $$;

-- ============================ T2: pulo de estado (assigned -> picked_up) ============================
do $$
declare r record; v_dr uuid; v_d uuid; v_org uuid; v_biz uuid;
begin
  select v into v_org from lc_ids where k='orgA'; select v into v_biz from lc_ids where k='bizA';
  perform set_config('request.jwt.claims', '{}'::text, true);  -- system: mk_assigned
  v_dr := pg_temp.mk_assigned(v_org, v_biz, 2.0);
  v_d  := pg_temp.lc_driver(v_dr);
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.drv_user(v_d))::text, true);  -- driver
  select * into r from public.transition_delivery(v_dr, 'picked_up');
  perform pg_temp.cr('T2_skip','invalid_transition', r.reason);
end $$;

-- ============================ T3: driver não entrega (in_transit -> delivered) ============================
do $$
declare r record; v_dr uuid; v_d uuid; v_org uuid; v_biz uuid;
begin
  select v into v_org from lc_ids where k='orgA'; select v into v_biz from lc_ids where k='bizA';
  perform set_config('request.jwt.claims', '{}'::text, true);  -- system: mk_assigned + advance
  v_dr := pg_temp.mk_assigned(v_org, v_biz, 3.0);
  v_d  := pg_temp.lc_driver(v_dr);
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.drv_user(v_d))::text, true);  -- driver
  select * into r from public.transition_delivery(v_dr, 'driver_to_pickup');
  select * into r from public.transition_delivery(v_dr, 'at_pickup');
  -- Sessão 12 (ADR-017 D3): picked_up exige pickup POD (gate).
  insert into public.proof_of_delivery(delivery_request_id, pod_type, storage_path)
    values (v_dr, 'pickup'::public.pod_type, 'pod/p.jpg');
  select * into r from public.transition_delivery(v_dr, 'picked_up');
  select * into r from public.transition_delivery(v_dr, 'in_transit');
  select * into r from public.transition_delivery(v_dr, 'delivered');
  perform pg_temp.cr('T3_no_deliver','not_authorized', r.reason);
end $$;

-- ============================ T4: driver não reatribui/cancela/falha ============================
do $$
declare r record; v_dr uuid; v_d uuid; v_org uuid; v_biz uuid;
begin
  select v into v_org from lc_ids where k='orgA'; select v into v_biz from lc_ids where k='bizA';
  perform set_config('request.jwt.claims', '{}'::text, true);  -- system: mk_assigned
  v_dr := pg_temp.mk_assigned(v_org, v_biz, 4.0);
  v_d  := pg_temp.lc_driver(v_dr);
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.drv_user(v_d))::text, true);  -- driver
  select * into r from public.transition_delivery(v_dr, 'searching_driver');
  perform pg_temp.cr('T4a_no_reassign','not_authorized', r.reason);
  select * into r from public.transition_delivery(v_dr, 'cancelled');
  perform pg_temp.cr('T4b_no_cancel','not_authorized', r.reason);
  select * into r from public.transition_delivery(v_dr, 'failed');
  perform pg_temp.cr('T4c_no_fail','not_authorized', r.reason);
end $$;

-- ============================ T5: business cancela pré-atribuição ============================
do $$
declare r record; v_org uuid; v_biz uuid; v_uBU uuid;
        v_draft uuid; v_quoted uuid; v_search uuid; v_assigned uuid;
begin
  select v into v_org from lc_ids where k='orgA'; select v into v_biz from lc_ids where k='bizA';
  select v into v_uBU from lc_ids where k='uBU';
  perform set_config('request.jwt.claims', '{}'::text, true);  -- system: setup mk_*
  v_draft   := pg_temp.mk_draft(v_org, v_biz, 5.0);           -- draft
  v_quoted  := pg_temp.mk_draft(v_org, v_biz, 5.1);           -- draft -> quoted
  select * into r from public.create_quote(v_quoted, 10000, 600);
  v_search  := pg_temp.mk_searching(v_org, v_biz, 5.2);       -- searching_driver
  v_assigned := pg_temp.mk_assigned(v_org, v_biz, 5.3);       -- assigned
  perform set_config('request.jwt.claims', json_build_object('sub', v_uBU)::text, true);  -- business
  select * into r from public.transition_delivery(v_draft, 'cancelled');
  perform pg_temp.cr('T5a_draft_cancel','transitioned', r.reason);
  select * into r from public.transition_delivery(v_quoted, 'cancelled');
  perform pg_temp.cr('T5b_quoted_cancel','transitioned', r.reason);
  select * into r from public.transition_delivery(v_search, 'cancelled');
  perform pg_temp.cr('T5c_search_cancel','transitioned', r.reason);
  select * into r from public.transition_delivery(v_assigned, 'cancelled');
  perform pg_temp.cr('T5d_assigned_cancel','not_authorized', r.reason);
end $$;

-- ============================ T6: admin pós-atribuição (cancel/fail/reassign) ============================
do $$
declare r record; v_org uuid; v_biz uuid; v_uAd uuid; v_a uuid; v_b uuid; v_c uuid;
begin
  select v into v_org from lc_ids where k='orgA'; select v into v_biz from lc_ids where k='bizA';
  select v into v_uAd from lc_ids where k='uAd';
  perform set_config('request.jwt.claims', '{}'::text, true);  -- system: mk_assigned
  v_a := pg_temp.mk_assigned(v_org, v_biz, 6.0);
  v_b := pg_temp.mk_assigned(v_org, v_biz, 6.1);
  v_c := pg_temp.mk_assigned(v_org, v_biz, 6.2);
  perform set_config('request.jwt.claims', json_build_object('sub', v_uAd)::text, true);  -- admin
  select * into r from public.transition_delivery(v_a, 'cancelled');
  perform pg_temp.cr('T6a_cancel','transitioned', r.reason);
  select * into r from public.transition_delivery(v_b, 'failed');
  perform pg_temp.cr('T6b_fail','transitioned', r.reason);
  select * into r from public.transition_delivery(v_c, 'searching_driver');
  perform pg_temp.cr('T6c_reassign','transitioned', r.reason);
  perform pg_temp.cr('T6c_count','1', pg_temp.reassign_count_of(v_c));
  perform pg_temp.cr('T6c_no_active','0', pg_temp.active_assign_count(v_c));
end $$;

-- ============================ T7: system-only guard (admin não bypassa) ============================
-- admin (operator) é bloqueado nas transições system-only; system path as executa.
do $$
declare r record; v_org uuid; v_biz uuid; v_uAd uuid; v_draft uuid; v_s1 uuid; v_s2 uuid;
begin
  select v into v_org from lc_ids where k='orgA'; select v into v_biz from lc_ids where k='bizA';
  select v into v_uAd from lc_ids where k='uAd';
  perform set_config('request.jwt.claims', '{}'::text, true);  -- system: mk_draft/mk_searching
  v_draft := pg_temp.mk_draft(v_org, v_biz, 7.0);            -- draft
  v_s1    := pg_temp.mk_searching(v_org, v_biz, 7.1);        -- searching_driver
  v_s2    := pg_temp.mk_searching(v_org, v_biz, 7.2);        -- searching_driver
  perform set_config('request.jwt.claims', json_build_object('sub', v_uAd)::text, true);  -- admin
  select * into r from public.transition_delivery(v_draft, 'quoted');
  perform pg_temp.cr('T7a_admin_no_quote','not_authorized', r.reason);
  select * into r from public.transition_delivery(v_s1, 'assigned');
  perform pg_temp.cr('T7b_admin_no_assign','not_authorized', r.reason);
  select * into r from public.transition_delivery(v_s2, 'expired');
  perform pg_temp.cr('T7c_admin_no_expire','not_authorized', r.reason);
  perform set_config('request.jwt.claims', '{}'::text, true);  -- system: executa
  select * into r from public.transition_delivery(v_draft, 'quoted');
  perform pg_temp.cr('T7d_system_quote','transitioned', r.reason);
  select * into r from public.transition_delivery(v_s2, 'expired');
  perform pg_temp.cr('T7e_system_expire','transitioned', r.reason);
end $$;

-- ============================ T8: limite de reatribuição (metadata max_reassignments:1) ============================
do $$
declare r record; v_org uuid; v_biz uuid; v_uAd uuid; v_dr uuid;
begin
  select v into v_org from lc_ids where k='orgA'; select v into v_biz from lc_ids where k='bizA';
  select v into v_uAd from lc_ids where k='uAd';
  perform set_config('request.jwt.claims', '{}'::text, true);  -- system: mk_assigned + owner update
  v_dr := pg_temp.mk_assigned(v_org, v_biz, 8.0);   -- assigned, reassignment_count=0
  update public.delivery_requests set reassignment_count = 1 where id = v_dr;
  perform set_config('request.jwt.claims', json_build_object('sub', v_uAd)::text, true);  -- admin
  select * into r from public.transition_delivery(v_dr, 'searching_driver', 'system', null, '{"max_reassignments":1}'::jsonb, null);
  perform pg_temp.cr('T8_limit','reassignment_limit_reached', r.reason);
  perform pg_temp.cr('T8_no_mutate_count','1', pg_temp.reassign_count_of(v_dr));
  perform pg_temp.cr('T8_no_mutate_status','assigned', pg_temp.dr_status(v_dr));
  perform pg_temp.cr('T8_still_active','1', pg_temp.active_assign_count(v_dr));
  select * into r from public.transition_delivery(v_dr, 'failed', 'system', null, '{"reason":"reassign limit"}'::jsonb, null);
  perform pg_temp.cr('T8_then_fail','transitioned', r.reason);
end $$;

-- ============================ T9: reatribuição supersede assignment ============================
do $$
declare r record; v_org uuid; v_biz uuid; v_uAd uuid; v_dr uuid;
begin
  select v into v_org from lc_ids where k='orgA'; select v into v_biz from lc_ids where k='bizA';
  select v into v_uAd from lc_ids where k='uAd';
  perform set_config('request.jwt.claims', '{}'::text, true);  -- system: mk_assigned
  v_dr := pg_temp.mk_assigned(v_org, v_biz, 9.0);   -- assigned, active assignment
  perform set_config('request.jwt.claims', json_build_object('sub', v_uAd)::text, true);  -- admin
  select * into r from public.transition_delivery(v_dr, 'searching_driver');
  perform pg_temp.cr('T9_reassign','transitioned', r.reason);
  perform pg_temp.cr('T9_count','1', pg_temp.reassign_count_of(v_dr));
  perform pg_temp.cr('T9_no_active','0', pg_temp.active_assign_count(v_dr));
  perform pg_temp.cr('T9_ended_reason','reassigned', pg_temp.assign_ended_reason(v_dr));
end $$;

-- ============================ T10: submit POD (driver) — não transita ============================
do $$
declare r record; v_dr uuid; v_d uuid; v_org uuid; v_biz uuid;
begin
  select v into v_org from lc_ids where k='orgA'; select v into v_biz from lc_ids where k='bizA';
  perform set_config('request.jwt.claims', '{}'::text, true);  -- system: mk_assigned + advance
  v_dr := pg_temp.mk_assigned(v_org, v_biz, 10.0);
  v_d  := pg_temp.lc_driver(v_dr);
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.drv_user(v_d))::text, true);  -- driver
  select * into r from public.transition_delivery(v_dr, 'driver_to_pickup');
  select * into r from public.transition_delivery(v_dr, 'at_pickup');
  -- Sessão 12 (ADR-017 D3): picked_up exige pickup POD (gate).
  insert into public.proof_of_delivery(delivery_request_id, pod_type, storage_path)
    values (v_dr, 'pickup'::public.pod_type, 'pod/p.jpg');
  select * into r from public.transition_delivery(v_dr, 'picked_up');
  select * into r from public.transition_delivery(v_dr, 'in_transit');
  select * into r from public.submit_proof_of_delivery(v_dr, 'delivery'::public.pod_type, 'pod/d.jpg', null, 'Receiver', null, null, null, null);
  perform pg_temp.cr('T10_submit','submitted', r.reason);
  perform pg_temp.cr('T10_no_transition','in_transit', pg_temp.dr_status(v_dr));
  perform pg_temp.cr('T10_ev_pod','t', pg_temp.has_event(v_dr,'pod_submitted'));
  perform pg_temp.cr('T10_pod_delivery','t', pg_temp.pod_exists(v_dr,'delivery'));
end $$;

-- ============================ T11: submit não-autorizado (driver sem assignment) ============================
do $$
declare r record; v_dr uuid; v_d1 uuid; v_d2 uuid; v_org uuid; v_biz uuid;
begin
  select v into v_org from lc_ids where k='orgA'; select v into v_biz from lc_ids where k='bizA';
  perform set_config('request.jwt.claims', '{}'::text, true);  -- system: mk_assigned + advance
  v_dr := pg_temp.mk_assigned(v_org, v_biz, 11.0);
  v_d1 := pg_temp.lc_driver(v_dr);
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.drv_user(v_d1))::text, true);  -- driver d1
  select * into r from public.transition_delivery(v_dr, 'driver_to_pickup');
  select * into r from public.transition_delivery(v_dr, 'at_pickup');
  -- Sessão 12 (ADR-017 D3): picked_up exige pickup POD (gate).
  insert into public.proof_of_delivery(delivery_request_id, pod_type, storage_path)
    values (v_dr, 'pickup'::public.pod_type, 'pod/p.jpg');
  select * into r from public.transition_delivery(v_dr, 'picked_up');
  select * into r from public.transition_delivery(v_dr, 'in_transit');
  v_d2 := pg_temp.mk_driver('t11d2@c.local','T11 D2','1102', 11.0 + 0.01);  -- driver sem assignment
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.drv_user(v_d2))::text, true);  -- driver d2
  select * into r from public.submit_proof_of_delivery(v_dr, 'delivery'::public.pod_type, 'pod/x.jpg', null, 'Rec', null, null, null, null);
  perform pg_temp.cr('T11_not_authorized','not_authorized', r.reason);
end $$;

-- ============================ T12: submit inválido (delivery POD sem storage/otp/receiver) ============================
do $$
declare r record; v_dr uuid; v_d uuid; v_org uuid; v_biz uuid;
begin
  select v into v_org from lc_ids where k='orgA'; select v into v_biz from lc_ids where k='bizA';
  perform set_config('request.jwt.claims', '{}'::text, true);  -- system: mk_assigned + advance
  v_dr := pg_temp.mk_assigned(v_org, v_biz, 12.0);
  v_d  := pg_temp.lc_driver(v_dr);
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.drv_user(v_d))::text, true);  -- driver
  select * into r from public.transition_delivery(v_dr, 'driver_to_pickup');
  select * into r from public.transition_delivery(v_dr, 'at_pickup');
  -- Sessão 12 (ADR-017 D3): picked_up exige pickup POD (gate).
  insert into public.proof_of_delivery(delivery_request_id, pod_type, storage_path)
    values (v_dr, 'pickup'::public.pod_type, 'pod/p.jpg');
  select * into r from public.transition_delivery(v_dr, 'picked_up');
  select * into r from public.transition_delivery(v_dr, 'in_transit');
  select * into r from public.submit_proof_of_delivery(v_dr, 'delivery'::public.pod_type, null, null, null, null, null, null, null);
  perform pg_temp.cr('T12_invalid_pod','invalid_pod', r.reason);
end $$;

-- ============================ T13: submit duplicado -> pod_already_submitted ============================
do $$
declare r record; v_dr uuid; v_d uuid; v_org uuid; v_biz uuid;
begin
  select v into v_org from lc_ids where k='orgA'; select v into v_biz from lc_ids where k='bizA';
  perform set_config('request.jwt.claims', '{}'::text, true);  -- system: mk_assigned + advance
  v_dr := pg_temp.mk_assigned(v_org, v_biz, 13.0);
  v_d  := pg_temp.lc_driver(v_dr);
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.drv_user(v_d))::text, true);  -- driver
  select * into r from public.transition_delivery(v_dr, 'driver_to_pickup');
  select * into r from public.transition_delivery(v_dr, 'at_pickup');
  -- Sessão 12 (ADR-017 D3): picked_up exige pickup POD (gate).
  insert into public.proof_of_delivery(delivery_request_id, pod_type, storage_path)
    values (v_dr, 'pickup'::public.pod_type, 'pod/p.jpg');
  select * into r from public.transition_delivery(v_dr, 'picked_up');
  select * into r from public.transition_delivery(v_dr, 'in_transit');
  select * into r from public.submit_proof_of_delivery(v_dr, 'delivery'::public.pod_type, 'pod/d.jpg', null, 'Receiver', null, null, null, null);
  perform pg_temp.cr('T13a_first','submitted', r.reason);
  select * into r from public.submit_proof_of_delivery(v_dr, 'delivery'::public.pod_type, 'pod/d2.jpg', null, 'Receiver2', null, null, null, null);
  perform pg_temp.cr('T13b_dup','pod_already_submitted', r.reason);
end $$;

-- ============================ T14: submit wrong_state (delivery POD com status assigned) ============================
do $$
declare r record; v_dr uuid; v_d uuid; v_org uuid; v_biz uuid;
begin
  select v into v_org from lc_ids where k='orgA'; select v into v_biz from lc_ids where k='bizA';
  perform set_config('request.jwt.claims', '{}'::text, true);  -- system: mk_assigned
  v_dr := pg_temp.mk_assigned(v_org, v_biz, 14.0);   -- assigned (não in_transit)
  v_d  := pg_temp.lc_driver(v_dr);
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.drv_user(v_d))::text, true);  -- driver
  select * into r from public.submit_proof_of_delivery(v_dr, 'delivery'::public.pod_type, 'pod/d.jpg', null, 'Receiver', null, null, null, null);
  perform pg_temp.cr('T14_wrong_state','wrong_state', r.reason);
end $$;

-- ============================ T15: confirm_delivery (system) com POD -> delivered ============================
do $$
declare r record; v_dr uuid; v_d uuid; v_org uuid; v_biz uuid;
begin
  select v into v_org from lc_ids where k='orgA'; select v into v_biz from lc_ids where k='bizA';
  perform set_config('request.jwt.claims', '{}'::text, true);  -- system: mk_assigned + advance
  v_dr := pg_temp.mk_assigned(v_org, v_biz, 15.0);
  v_d  := pg_temp.lc_driver(v_dr);
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.drv_user(v_d))::text, true);  -- driver: avança + submete
  select * into r from public.transition_delivery(v_dr, 'driver_to_pickup');
  select * into r from public.transition_delivery(v_dr, 'at_pickup');
  -- Sessão 12 (ADR-017 D3): picked_up exige pickup POD (gate).
  insert into public.proof_of_delivery(delivery_request_id, pod_type, storage_path)
    values (v_dr, 'pickup'::public.pod_type, 'pod/p.jpg');
  select * into r from public.transition_delivery(v_dr, 'picked_up');
  select * into r from public.transition_delivery(v_dr, 'in_transit');
  select * into r from public.submit_proof_of_delivery(v_dr, 'delivery'::public.pod_type, 'pod/d.jpg', null, 'Receiver', null, null, null, null);
  perform set_config('request.jwt.claims', '{}'::text, true);  -- system: confirma
  select * into r from public.confirm_delivery(v_dr);
  perform pg_temp.cr('T15_confirm','delivered', r.reason);
  perform pg_temp.cr('T15_status','delivered', pg_temp.dr_status(v_dr));
  perform pg_temp.cr('T15_ev_delivered','t', pg_temp.has_event(v_dr,'delivered'));
  perform pg_temp.cr('T15_delivered_at','t', pg_temp.delivered_at_set(v_dr));
end $$;

-- ============================ T16: confirm sem POD -> pod_required ============================
do $$
declare r record; v_dr uuid; v_d uuid; v_org uuid; v_biz uuid;
begin
  select v into v_org from lc_ids where k='orgA'; select v into v_biz from lc_ids where k='bizA';
  perform set_config('request.jwt.claims', '{}'::text, true);  -- system: mk_assigned + advance
  v_dr := pg_temp.mk_assigned(v_org, v_biz, 16.0);
  v_d  := pg_temp.lc_driver(v_dr);
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.drv_user(v_d))::text, true);  -- driver: avança (sem POD)
  select * into r from public.transition_delivery(v_dr, 'driver_to_pickup');
  select * into r from public.transition_delivery(v_dr, 'at_pickup');
  -- Sessão 12 (ADR-017 D3): picked_up exige pickup POD (gate).
  insert into public.proof_of_delivery(delivery_request_id, pod_type, storage_path)
    values (v_dr, 'pickup'::public.pod_type, 'pod/p.jpg');
  select * into r from public.transition_delivery(v_dr, 'picked_up');
  select * into r from public.transition_delivery(v_dr, 'in_transit');
  perform set_config('request.jwt.claims', '{}'::text, true);  -- system: confirma sem POD
  select * into r from public.confirm_delivery(v_dr);
  perform pg_temp.cr('T16_no_pod','pod_required', r.reason);
end $$;

-- ============================ T17: confirm system-only (admin -> not_authorized) ============================
do $$
declare r record; v_dr uuid; v_d uuid; v_org uuid; v_biz uuid; v_uAd uuid;
begin
  select v into v_org from lc_ids where k='orgA'; select v into v_biz from lc_ids where k='bizA';
  select v into v_uAd from lc_ids where k='uAd';
  perform set_config('request.jwt.claims', '{}'::text, true);  -- system: mk_assigned + advance
  v_dr := pg_temp.mk_assigned(v_org, v_biz, 17.0);
  v_d  := pg_temp.lc_driver(v_dr);
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.drv_user(v_d))::text, true);  -- driver: avança + POD
  select * into r from public.transition_delivery(v_dr, 'driver_to_pickup');
  select * into r from public.transition_delivery(v_dr, 'at_pickup');
  -- Sessão 12 (ADR-017 D3): picked_up exige pickup POD (gate).
  insert into public.proof_of_delivery(delivery_request_id, pod_type, storage_path)
    values (v_dr, 'pickup'::public.pod_type, 'pod/p.jpg');
  select * into r from public.transition_delivery(v_dr, 'picked_up');
  select * into r from public.transition_delivery(v_dr, 'in_transit');
  select * into r from public.submit_proof_of_delivery(v_dr, 'delivery'::public.pod_type, 'pod/d.jpg', null, 'Receiver', null, null, null, null);
  perform set_config('request.jwt.claims', json_build_object('sub', v_uAd)::text, true);  -- admin tenta confirmar
  select * into r from public.confirm_delivery(v_dr);
  perform pg_temp.cr('T17_admin_no_confirm','not_authorized', r.reason);
end $$;

-- ============================ T18: confirm wrong_state (picked_up, não in_transit) ============================
do $$
declare r record; v_dr uuid; v_d uuid; v_org uuid; v_biz uuid;
begin
  select v into v_org from lc_ids where k='orgA'; select v into v_biz from lc_ids where k='bizA';
  perform set_config('request.jwt.claims', '{}'::text, true);  -- system: mk_assigned + advance
  v_dr := pg_temp.mk_assigned(v_org, v_biz, 18.0);
  v_d  := pg_temp.lc_driver(v_dr);
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.drv_user(v_d))::text, true);  -- driver: avança até picked_up
  select * into r from public.transition_delivery(v_dr, 'driver_to_pickup');
  select * into r from public.transition_delivery(v_dr, 'at_pickup');
  -- Sessão 12 (ADR-017 D3): picked_up exige pickup POD (gate).
  insert into public.proof_of_delivery(delivery_request_id, pod_type, storage_path)
    values (v_dr, 'pickup'::public.pod_type, 'pod/p.jpg');
  select * into r from public.transition_delivery(v_dr, 'picked_up');
  perform set_config('request.jwt.claims', '{}'::text, true);  -- system: insere POD + confirma
  insert into public.proof_of_delivery(delivery_request_id, pod_type, storage_path, receiver_name)
    values (v_dr, 'delivery'::public.pod_type, 'pod/d.jpg', 'Receiver');
  select * into r from public.confirm_delivery(v_dr);
  perform pg_temp.cr('T18_wrong_state','invalid_transition', r.reason);
end $$;

-- ============================ T19: POD gate direto (system sem POD -> pod_required) ============================
do $$
declare r record; v_dr uuid; v_d uuid; v_org uuid; v_biz uuid;
begin
  select v into v_org from lc_ids where k='orgA'; select v into v_biz from lc_ids where k='bizA';
  perform set_config('request.jwt.claims', '{}'::text, true);  -- system: mk_assigned + advance + gate
  v_dr := pg_temp.mk_assigned(v_org, v_biz, 19.0);
  v_d  := pg_temp.lc_driver(v_dr);
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.drv_user(v_d))::text, true);  -- driver: avança (sem POD)
  select * into r from public.transition_delivery(v_dr, 'driver_to_pickup');
  select * into r from public.transition_delivery(v_dr, 'at_pickup');
  -- Sessão 12 (ADR-017 D3): picked_up exige pickup POD (gate).
  insert into public.proof_of_delivery(delivery_request_id, pod_type, storage_path)
    values (v_dr, 'pickup'::public.pod_type, 'pod/p.jpg');
  select * into r from public.transition_delivery(v_dr, 'picked_up');
  select * into r from public.transition_delivery(v_dr, 'in_transit');
  perform set_config('request.jwt.claims', '{}'::text, true);  -- system: delivered direto sem POD
  select * into r from public.transition_delivery(v_dr, 'delivered');
  perform pg_temp.cr('T19_gate','pod_required', r.reason);
end $$;

-- ============================ T20: pickup POD (driver) — sem transição ============================
do $$
declare r record; v_dr uuid; v_d uuid; v_org uuid; v_biz uuid;
begin
  select v into v_org from lc_ids where k='orgA'; select v into v_biz from lc_ids where k='bizA';
  perform set_config('request.jwt.claims', '{}'::text, true);  -- system: mk_assigned + advance
  v_dr := pg_temp.mk_assigned(v_org, v_biz, 20.0);
  v_d  := pg_temp.lc_driver(v_dr);
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.drv_user(v_d))::text, true);  -- driver
  select * into r from public.transition_delivery(v_dr, 'driver_to_pickup');
  select * into r from public.transition_delivery(v_dr, 'at_pickup');
  -- Sessão 12 (ADR-017 D3): pickup POD submetido ANTES de picked_up (gate exige). Submeter
  -- POD não transita (status permanece at_pickup); só transition_delivery('picked_up') transita.
  select * into r from public.submit_proof_of_delivery(v_dr, 'pickup'::public.pod_type, 'pod/p.jpg', null, null, null, null, null, null);
  perform pg_temp.cr('T20_pickup_submit','submitted', r.reason);
  perform pg_temp.cr('T20_no_transition','at_pickup', pg_temp.dr_status(v_dr));
  perform pg_temp.cr('T20_ev_pod','t', pg_temp.has_event(v_dr,'pod_submitted'));
  perform pg_temp.cr('T20_pod_pickup','t', pg_temp.pod_exists(v_dr,'pickup'));
  select * into r from public.transition_delivery(v_dr, 'picked_up');
  perform pg_temp.cr('T20_then_picked_up','transitioned', r.reason);
  perform pg_temp.cr('T20_status','picked_up', pg_temp.dr_status(v_dr));
end $$;

-- ============================ T21: cancel/fail reason capturado de metadata ============================
do $$
declare r record; v_org uuid; v_biz uuid; v_uAd uuid; v_c uuid; v_f uuid;
begin
  select v into v_org from lc_ids where k='orgA'; select v into v_biz from lc_ids where k='bizA';
  select v into v_uAd from lc_ids where k='uAd';
  perform set_config('request.jwt.claims', '{}'::text, true);  -- system: mk_assigned
  v_c := pg_temp.mk_assigned(v_org, v_biz, 21.0);
  v_f := pg_temp.mk_assigned(v_org, v_biz, 21.1);
  perform set_config('request.jwt.claims', json_build_object('sub', v_uAd)::text, true);  -- admin
  select * into r from public.transition_delivery(v_c, 'cancelled', 'system', null, '{"reason":"cust cancel"}'::jsonb, null);
  perform pg_temp.cr('T21a_cancel','transitioned', r.reason);
  perform pg_temp.cr('T21a_cancel_reason','cust cancel', pg_temp.cancelled_reason_of(v_c));
  select * into r from public.transition_delivery(v_f, 'failed', 'system', null, '{"reason":"no show"}'::jsonb, null);
  perform pg_temp.cr('T21b_fail','transitioned', r.reason);
  perform pg_temp.cr('T21b_fail_reason','no show', pg_temp.failed_reason_of(v_f));
end $$;

-- ============================ T22: draft -> cancelled (business, nova transição em M) ============================
do $$
declare r record; v_org uuid; v_biz uuid; v_uBU uuid; v_dr uuid;
begin
  select v into v_org from lc_ids where k='orgA'; select v into v_biz from lc_ids where k='bizA';
  select v into v_uBU from lc_ids where k='uBU';
  perform set_config('request.jwt.claims', '{}'::text, true);  -- system: mk_draft
  v_dr := pg_temp.mk_draft(v_org, v_biz, 22.0);   -- draft
  perform set_config('request.jwt.claims', json_build_object('sub', v_uBU)::text, true);  -- business
  select * into r from public.transition_delivery(v_dr, 'cancelled');
  perform pg_temp.cr('T22_draft_cancel','transitioned', r.reason);
  perform pg_temp.cr('T22_status','cancelled', pg_temp.dr_status(v_dr));
end $$;

-- ============================ Consolidated verdict ============================
-- num_failed()=0 é a autoridade (finish() emite 0 rows neste dev — Sessão 08).
select
  (select count(*) from lc_results) as total,
  (select count(*) from lc_results where pass) as passed,
  (select count(*) from lc_results where not pass) as failed,
  (select string_agg(test, ',' order by test) from lc_results where not pass) as failures;

rollback;