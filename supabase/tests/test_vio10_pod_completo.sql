-- test_vio10_pod_completo.sql — POD completo (Sessão 12, ADR-017): OTP do recebedor,
-- gate de geolocalização, gate de pickup POD, Storage estrutural.
--
-- Valida:
--   D1 — ciclo de vida do OTP (generate_delivery_otp system-only, validação em submit,
--        hash salt+sha256, TTL, lockout, consumed_at atômico, regenerate upsert).
--   D2 — gate de geo em in_transit->delivered (tolerância configurável via metadata /
--        confirm_delivery(p_geo_tolerance_m); default 200m; skip quando POD sem location).
--   D3 — gate de pickup POD em at_pickup->picked_up (pickup_pod_required).
--   D5 — bucket pod-photos + policy pod_photos_insert (validação ESTRUTURAL apenas —
--        Storage RLS comportamental é DEFERIDA, não exercitável via curl /database/query).
--
-- Geometria: cada caso usa base lng distinta (isolamento). Delivery_point em (0, lng+0.05).
-- Distâncias ao delivery_point via offset de longitude (1° ~111320m no equador):
--   +150m -> +0.00134778 ; +300m -> +0.00269555.
--
-- Executa em begin/rollback (clean-slate). Setup como owner (system path, auth.uid()=null).
-- DISCIPLINA DE JWT (lição Sessão 06/11): set_config(...,true) é is_local — persiste até o fim
-- da TRANSAÇÃO. CADA bloco: 1. reseta '{}' antes de mk_*/generate/confirm (system);
-- 2. seta driver antes de submit/transition autenticadas; 3. reseta '{}' antes de
-- system-only (generate_delivery_otp, confirm_delivery).
--
-- pgTAP: num_failed()=0 é a autoridade (finish() emite 0 rows neste dev). Resultados
-- consolidados num único SELECT final em pc_results.

set search_path to public, extensions;
begin;

create temp table pc_ids(k text primary key, v uuid);
create temp table pc_map(dr_id uuid primary key, driver_id uuid);
create temp table pc_results(test text, expected text, actual text, pass boolean);

-- cr: registra expected vs actual em pc_results.
create or replace function pg_temp.pc_cr(t text, exp text, act text) returns void
language plpgsql as $$
begin
  insert into pc_results(test, expected, actual, pass) values (t, exp, act, exp = act);
  if exp <> act then raise notice 'FAIL %: exp=% act=%', t, exp, act; end if;
end $$;

-- ============================ SETUP (org + biz + pricing) ============================
do $$
declare v_org uuid; v_biz uuid;
begin
  perform set_config('request.jwt.claims', '{}'::text, true);
  insert into public.organizations(name) values('OrgPC') returning id into v_org;
  insert into public.businesses(organization_id,name) values(v_org,'BizPC') returning id into v_biz;
  insert into public.pricing_rules
    (organization_id, vehicle_type, base_cents, per_km_cents, per_minute_cents,
     urgency_add_cents, min_price_cents, platform_fee_cents, is_active)
  values (v_org,'motorcycle',500,100,10,200,800,120,true);
  insert into pc_ids values ('org',v_org),('biz',v_biz);
end $$;

-- ============================ Helpers (mesmo molde do lifecycle) ============================
create or replace function pg_temp.pc_mk_driver(p_email text, p_full text, p_phone text, p_lng double precision) returns uuid
language plpgsql set search_path = public, extensions, pg_catalog
as $$
declare v_uid uuid := gen_random_uuid(); v_did uuid; v_vid uuid;
begin
  insert into auth.users(id,email) values(v_uid, p_email);
  insert into public.drivers(user_id, full_name, phone, account_status, current_availability_status)
    values(v_uid, p_full, p_phone, 'active'::public.driver_account_status, 'available'::public.driver_availability_status)
    returning id into v_did;
  insert into public.vehicles(driver_id, vehicle_type, plate)
    values(v_did, 'motorcycle'::public.vehicle_type, replace(p_full,' ','')||'-PLT')
    returning id into v_vid;
  update public.drivers set current_vehicle_id = v_vid where id = v_did;
  insert into public.driver_locations(driver_id, position, captured_at)
    values (v_did, st_setsrid(st_makepoint(p_lng, 0.0), 4326)::geography(Point,4326), now());
  return v_did;
end $$;

create or replace function pg_temp.pc_mk_draft(p_org uuid, p_biz uuid, p_lng double precision) returns uuid
language plpgsql set search_path = public, extensions, pg_catalog
as $$
declare r record; v_items jsonb := '[{"description":"cx","quantity":1}]'::jsonb;
begin
  select * into r from public.create_delivery_request(
    p_org, p_biz, null,
    'Pickup', 0.0, p_lng, 'PN', '555', 'Delivery', 0.0, p_lng + 0.05, 'DN', '666',
    'motorcycle'::public.vehicle_type, 'standard'::public.delivery_priority,
    null, 'dashboard', null, null, null, v_items, null);
  return r.delivery_request_id;
end $$;

create or replace function pg_temp.pc_mk_searching(p_org uuid, p_biz uuid, p_lng double precision) returns uuid
language plpgsql set search_path = public, extensions, pg_catalog
as $$
declare v_dr uuid; r record;
begin
  v_dr := pg_temp.pc_mk_draft(p_org, p_biz, p_lng);
  select * into r from public.create_quote(v_dr, 10000, 600);
  select * into r from public.confirm_quote(v_dr);
  return v_dr;
end $$;

create or replace function pg_temp.pc_offer_of(p_round uuid, p_driver uuid) returns uuid
language sql security definer set search_path = public, pg_catalog
as $$ select id from public.delivery_offers where dispatch_round_id=p_round and driver_id=p_driver $$;

create or replace function pg_temp.pc_do_respond(p_offer uuid, p_driver uuid, p_rt text) returns boolean
language plpgsql set search_path = public, pg_catalog
as $$
declare r record;
begin
  select * into r from public.respond_to_offer(p_offer, p_driver, p_rt::public.bid_response_type, null);
  return r.ok;
end $$;

-- pc_mk_assigned: leva a `assigned` com driver atribuído. Requer system path (caller resetou JWT).
create or replace function pg_temp.pc_mk_assigned(p_org uuid, p_biz uuid, p_lng double precision) returns uuid
language plpgsql set search_path = public, extensions, pg_catalog
as $$
declare v_dr uuid; v_did uuid; r record; v_round uuid; v_offer uuid;
begin
  v_dr := pg_temp.pc_mk_searching(p_org, p_biz, p_lng);
  v_did := pg_temp.pc_mk_driver('drv_'||p_lng::text||'@c.local', 'Drv '||p_lng::text, '5', p_lng + 0.001);
  select * into r from public.open_dispatch_round(v_dr, 5000, 10, 1500, 3600);
  v_round := r.round_id;
  v_offer := pg_temp.pc_offer_of(v_round, v_did);
  perform pg_temp.pc_do_respond(v_offer, v_did, 'accept');
  select * into r from public.claim_delivery(v_dr, v_did, v_round, v_offer, null, null);
  insert into pc_map(dr_id, driver_id) values (v_dr, v_did);
  return v_dr;
end $$;

-- pc_mk_in_transit: assigned -> ... -> in_transit (com pickup POD inserido p/ gate D3).
-- Requer system path no início (seta JWT internamente).
create or replace function pg_temp.pc_mk_in_transit(p_org uuid, p_biz uuid, p_lng double precision) returns uuid
language plpgsql set search_path = public, extensions, pg_catalog
as $$
declare v_dr uuid; v_d uuid; r record;
begin
  perform set_config('request.jwt.claims', '{}'::text, true);
  v_dr := pg_temp.pc_mk_assigned(p_org, p_biz, p_lng);
  v_d  := (select driver_id from pc_map where dr_id = v_dr);
  perform set_config('request.jwt.claims', json_build_object('sub',
    (select user_id from public.drivers where id = v_d))::text, true);  -- driver
  select * into r from public.transition_delivery(v_dr, 'driver_to_pickup');
  select * into r from public.transition_delivery(v_dr, 'at_pickup');
  insert into public.proof_of_delivery(delivery_request_id, pod_type, storage_path)
    values (v_dr, 'pickup'::public.pod_type, 'pod/p.jpg');
  select * into r from public.transition_delivery(v_dr, 'picked_up');
  select * into r from public.transition_delivery(v_dr, 'in_transit');
  perform set_config('request.jwt.claims', '{}'::text, true);  -- volta system
  return v_dr;
end $$;

-- ============================ Helpers de inspeção (DEFINER, bypass RLS) ============================
create or replace function pg_temp.pc_status(p_id uuid) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select status::text from public.delivery_requests where id = p_id $$;
create or replace function pg_temp.pc_has_event(p_dr uuid, p_ev text) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select case when exists(select 1 from public.delivery_events where delivery_request_id=p_dr and event_type=p_ev::public.delivery_event_type) then 't' else 'f' end $$;
create or replace function pg_temp.pc_event_actor(p_dr uuid, p_ev text) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select actor_type from public.delivery_events where delivery_request_id=p_dr and event_type=p_ev::public.delivery_event_type order by created_at desc, id desc limit 1 $$;
create or replace function pg_temp.pc_pod_exists(p_dr uuid, p_pt text) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select case when exists(select 1 from public.proof_of_delivery where delivery_request_id=p_dr and pod_type=p_pt::public.pod_type) then 't' else 'f' end $$;
create or replace function pg_temp.pc_drv_user(p_driver uuid) returns uuid
language sql security definer set search_path = public, pg_catalog
as $$ select user_id from public.drivers where id = p_driver $$;
create or replace function pg_temp.pc_driver(p_dr uuid) returns uuid
language sql security definer set search_path = public, pg_catalog
as $$ select driver_id from pc_map where dr_id = p_dr $$;
-- delivery_otps:
create or replace function pg_temp.pc_otp_attempts(p_dr uuid) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select coalesce(attempts::text,'na') from public.delivery_otps where delivery_request_id = p_dr $$;
create or replace function pg_temp.pc_otp_consumed(p_dr uuid) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select case when consumed_at is not null then 't' else 'f' end from public.delivery_otps where delivery_request_id = p_dr $$;
create or replace function pg_temp.pc_otp_exists(p_dr uuid) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select case when exists(select 1 from public.delivery_otps where delivery_request_id=p_dr) then 't' else 'f' end $$;

-- ============================ A. Geração de OTP (D1/D9) ============================
-- A1: system-only — driver não gera.
do $$
declare r record; v_dr uuid; v_d uuid; v_org uuid; v_biz uuid;
begin
  select v into v_org from pc_ids where k='org'; select v into v_biz from pc_ids where k='biz';
  perform set_config('request.jwt.claims', '{}'::text, true);
  v_dr := pg_temp.pc_mk_assigned(v_org, v_biz, 100.0);
  v_d  := pg_temp.pc_driver(v_dr);
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.pc_drv_user(v_d))::text, true);  -- driver
  select * into r from public.generate_delivery_otp(v_dr);
  perform pg_temp.pc_cr('A1_driver_no_gen','not_authorized', r.reason);
end $$;

-- A2: system gera — reason + código 6 dígitos + evento otp_generated (actor system).
do $$
declare r record; v_dr uuid; v_org uuid; v_biz uuid;
begin
  select v into v_org from pc_ids where k='org'; select v into v_biz from pc_ids where k='biz';
  perform set_config('request.jwt.claims', '{}'::text, true);
  v_dr := pg_temp.pc_mk_assigned(v_org, v_biz, 100.5);  -- assigned: OTP permitido
  select * into r from public.generate_delivery_otp(v_dr);
  perform pg_temp.pc_cr('A2_gen','generated', r.reason);
  perform pg_temp.pc_cr('A2_code_len','6', length(r.otp_code)::text);
  perform pg_temp.pc_cr('A2_event','t', pg_temp.pc_has_event(v_dr,'otp_generated'));
  perform pg_temp.pc_cr('A2_actor','system', pg_temp.pc_event_actor(v_dr,'otp_generated'));
end $$;

-- A3: wrong_state — delivery em draft não aceita OTP.
do $$
declare r record; v_dr uuid; v_org uuid; v_biz uuid;
begin
  select v into v_org from pc_ids where k='org'; select v into v_biz from pc_ids where k='biz';
  perform set_config('request.jwt.claims', '{}'::text, true);
  v_dr := pg_temp.pc_mk_draft(v_org, v_biz, 101.0);  -- draft
  select * into r from public.generate_delivery_otp(v_dr);
  perform pg_temp.pc_cr('A3_wrong_state','wrong_state', r.reason);
end $$;

-- A4: regenerate (upsert) reseta attempts e consumed_at.
do $$
declare r record; v_dr uuid; v_d uuid; v_org uuid; v_biz uuid; v_code text; v_wrong text;
begin
  select v into v_org from pc_ids where k='org'; select v into v_biz from pc_ids where k='biz';
  v_dr := pg_temp.pc_mk_in_transit(v_org, v_biz, 102.0);  -- in_transit, JWT system
  v_d  := pg_temp.pc_driver(v_dr);
  select * into r from public.generate_delivery_otp(v_dr); v_code := r.otp_code;
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.pc_drv_user(v_d))::text, true);  -- driver
  v_wrong := case when v_code <> '000000' then '000000' else '111111' end;  -- garantido diferente
  select * into r from public.submit_proof_of_delivery(v_dr, 'delivery'::public.pod_type, null, v_wrong, 'Rec', null, null, null, null);
  perform pg_temp.pc_cr('A4a_wrong_invalid','otp_invalid', r.reason);
  perform pg_temp.pc_cr('A4a_attempts_1','1', pg_temp.pc_otp_attempts(v_dr));
  perform set_config('request.jwt.claims', '{}'::text, true);  -- system regenera
  select * into r from public.generate_delivery_otp(v_dr);
  perform pg_temp.pc_cr('A4b_regenerated','generated', r.reason);
  perform pg_temp.pc_cr('A4b_attempts_reset','0', pg_temp.pc_otp_attempts(v_dr));
  perform pg_temp.pc_cr('A4b_consumed_reset','f', pg_temp.pc_otp_consumed(v_dr));
end $$;

-- ============================ B. Validação de OTP no submit (D1/D4) ============================
-- B1: generate -> submit correto -> submitted + consumed_at set.
do $$
declare r record; v_dr uuid; v_d uuid; v_org uuid; v_biz uuid; v_code text;
begin
  select v into v_org from pc_ids where k='org'; select v into v_biz from pc_ids where k='biz';
  v_dr := pg_temp.pc_mk_in_transit(v_org, v_biz, 110.0);
  v_d  := pg_temp.pc_driver(v_dr);
  select * into r from public.generate_delivery_otp(v_dr); v_code := r.otp_code;  -- system
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.pc_drv_user(v_d))::text, true);  -- driver
  select * into r from public.submit_proof_of_delivery(v_dr, 'delivery'::public.pod_type, null, v_code, 'Rec', null, null, null, null);
  perform pg_temp.pc_cr('B1_submitted','submitted', r.reason);
  perform pg_temp.pc_cr('B1_consumed','t', pg_temp.pc_otp_consumed(v_dr));
end $$;

-- B2: submit errado -> otp_invalid + attempts=1.
do $$
declare r record; v_dr uuid; v_d uuid; v_org uuid; v_biz uuid; v_code text; v_wrong text;
begin
  select v into v_org from pc_ids where k='org'; select v into v_biz from pc_ids where k='biz';
  v_dr := pg_temp.pc_mk_in_transit(v_org, v_biz, 111.0);
  v_d  := pg_temp.pc_driver(v_dr);
  select * into r from public.generate_delivery_otp(v_dr); v_code := r.otp_code;
  v_wrong := case when v_code <> '000000' then '000000' else '111111' end;
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.pc_drv_user(v_d))::text, true);
  select * into r from public.submit_proof_of_delivery(v_dr, 'delivery'::public.pod_type, null, v_wrong, 'Rec', null, null, null, null);
  perform pg_temp.pc_cr('B2_invalid','otp_invalid', r.reason);
  perform pg_temp.pc_cr('B2_attempts_1','1', pg_temp.pc_otp_attempts(v_dr));
end $$;

-- B3: lockout — 3 errados (max_attempts=3) -> 3º otp_max_attempts; attempts=3.
do $$
declare r record; v_dr uuid; v_d uuid; v_org uuid; v_biz uuid; v_code text; v_wrong text; i int;
begin
  select v into v_org from pc_ids where k='org'; select v into v_biz from pc_ids where k='biz';
  v_dr := pg_temp.pc_mk_in_transit(v_org, v_biz, 112.0);
  v_d  := pg_temp.pc_driver(v_dr);
  select * into r from public.generate_delivery_otp(v_dr, 900, 3); v_code := r.otp_code;  -- max_attempts=3
  v_wrong := case when v_code <> '000000' then '000000' else '111111' end;
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.pc_drv_user(v_d))::text, true);
  for i in 1..3 loop
    select * into r from public.submit_proof_of_delivery(v_dr, 'delivery'::public.pod_type, null, v_wrong, 'Rec', null, null, null, null);
  end loop;
  perform pg_temp.pc_cr('B3_locked','otp_max_attempts', r.reason);
  perform pg_temp.pc_cr('B3_attempts_3','3', pg_temp.pc_otp_attempts(v_dr));
end $$;

-- B4: otp_expired — expira o OTP (now() é constante na tx; empurra expires_at para o passado).
do $$
declare r record; v_dr uuid; v_d uuid; v_org uuid; v_biz uuid; v_code text;
begin
  select v into v_org from pc_ids where k='org'; select v into v_biz from pc_ids where k='biz';
  v_dr := pg_temp.pc_mk_in_transit(v_org, v_biz, 113.0);
  v_d  := pg_temp.pc_driver(v_dr);
  select * into r from public.generate_delivery_otp(v_dr); v_code := r.otp_code;
  update public.delivery_otps set expires_at = now() - interval '10 seconds'
    where delivery_request_id = v_dr;  -- owner: simula passagem do TTL
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.pc_drv_user(v_d))::text, true);
  select * into r from public.submit_proof_of_delivery(v_dr, 'delivery'::public.pod_type, null, v_code, 'Rec', null, null, null, null);
  perform pg_temp.pc_cr('B4_expired','otp_expired', r.reason);
end $$;

-- B5: otp_not_generated — delivery POD com otp_code mas nenhum OTP gerado.
do $$
declare r record; v_dr uuid; v_d uuid; v_org uuid; v_biz uuid;
begin
  select v into v_org from pc_ids where k='org'; select v into v_biz from pc_ids where k='biz';
  v_dr := pg_temp.pc_mk_in_transit(v_org, v_biz, 114.0);
  v_d  := pg_temp.pc_driver(v_dr);
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.pc_drv_user(v_d))::text, true);
  select * into r from public.submit_proof_of_delivery(v_dr, 'delivery'::public.pod_type, null, '123456', 'Rec', null, null, null, null);
  perform pg_temp.pc_cr('B5_not_generated','otp_not_generated', r.reason);
end $$;

-- B6: foto-only (sem otp_code) -> submitted (sem validação OTP; either-or preservado).
do $$
declare r record; v_dr uuid; v_d uuid; v_org uuid; v_biz uuid;
begin
  select v into v_org from pc_ids where k='org'; select v into v_biz from pc_ids where k='biz';
  v_dr := pg_temp.pc_mk_in_transit(v_org, v_biz, 115.0);
  v_d  := pg_temp.pc_driver(v_dr);
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.pc_drv_user(v_d))::text, true);
  select * into r from public.submit_proof_of_delivery(v_dr, 'delivery'::public.pod_type, 'pod/d.jpg', null, 'Rec', null, null, null, null);
  perform pg_temp.pc_cr('B6_foto_only','submitted', r.reason);
end $$;

-- ============================ C. Replay POD (unique) ============================
-- C1: 2º submit reusando o MESMO OTP (já consumido) -> otp_already_used (o gate de OTP
-- roda ANTES do insert do POD). 3º submit foto-only (sem otp) -> bypassa o gate de OTP e
-- bate no unique (delivery_request_id, pod_type) -> pod_already_submitted. Documenta os
-- dois caminhos de rejeição de 2º POD.
do $$
declare r record; v_dr uuid; v_d uuid; v_org uuid; v_biz uuid; v_code text;
begin
  select v into v_org from pc_ids where k='org'; select v into v_biz from pc_ids where k='biz';
  v_dr := pg_temp.pc_mk_in_transit(v_org, v_biz, 116.0);
  v_d  := pg_temp.pc_driver(v_dr);
  select * into r from public.generate_delivery_otp(v_dr); v_code := r.otp_code;
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.pc_drv_user(v_d))::text, true);
  select * into r from public.submit_proof_of_delivery(v_dr, 'delivery'::public.pod_type, null, v_code, 'Rec', null, null, null, null);
  perform pg_temp.pc_cr('C1a_first','submitted', r.reason);
  select * into r from public.submit_proof_of_delivery(v_dr, 'delivery'::public.pod_type, null, v_code, 'Rec2', null, null, null, null);
  perform pg_temp.pc_cr('C1b_otp_already_used','otp_already_used', r.reason);
  select * into r from public.submit_proof_of_delivery(v_dr, 'delivery'::public.pod_type, 'pod/d2.jpg', null, 'Rec3', null, null, null, null);
  perform pg_temp.pc_cr('C1c_pod_already_submitted','pod_already_submitted', r.reason);
end $$;

-- ============================ D. Gate de geolocalização (D2) ============================
-- Delivery_point em (0, lng+0.05). POD location via submit_proof_of_delivery(lat,lng).
do $$
declare r record; v_dr uuid; v_org uuid; v_biz uuid; v_dl double precision;
begin
  select v into v_org from pc_ids where k='org'; select v into v_biz from pc_ids where k='biz';
  v_dl := 120.0 + 0.05;  -- delivery_point longitude
  v_dr := pg_temp.pc_mk_in_transit(v_org, v_biz, 120.0);
  perform set_config('request.jwt.claims', '{}'::text, true);
  -- POD delivery exatamente no delivery_point (dist 0) -> geo ok.
  insert into public.proof_of_delivery(delivery_request_id, pod_type, storage_path, receiver_name, location_point)
    values (v_dr, 'delivery'::public.pod_type, 'pod/d.jpg', 'Rec',
            st_setsrid(st_makepoint(v_dl, 0.0),4326)::geography(Point,4326));
  select * into r from public.confirm_delivery(v_dr);  -- default tol 200m
  perform pg_temp.pc_cr('D1_delivered','delivered', r.reason);
  perform pg_temp.pc_cr('D1_status','delivered', pg_temp.pc_status(v_dr));
end $$;

-- D2: POD a +300m, default tol 200m -> pod_geolocation_out_of_range; status permanece in_transit.
do $$
declare r record; v_dr uuid; v_org uuid; v_biz uuid; v_dl double precision;
begin
  select v into v_org from pc_ids where k='org'; select v into v_biz from pc_ids where k='biz';
  v_dl := 121.0 + 0.05;
  v_dr := pg_temp.pc_mk_in_transit(v_org, v_biz, 121.0);
  perform set_config('request.jwt.claims', '{}'::text, true);
  insert into public.proof_of_delivery(delivery_request_id, pod_type, storage_path, receiver_name, location_point)
    values (v_dr, 'delivery'::public.pod_type, 'pod/d.jpg', 'Rec',
            st_setsrid(st_makepoint(v_dl + 0.00269555, 0.0),4326)::geography(Point,4326));  -- +300m
  select * into r from public.confirm_delivery(v_dr);
  perform pg_temp.pc_cr('D2_out_of_range','pod_geolocation_out_of_range', r.reason);
  perform pg_temp.pc_cr('D2_status_intransit','in_transit', pg_temp.pc_status(v_dr));
end $$;

-- D3: POD sem location -> skip do gate -> delivered.
do $$
declare r record; v_dr uuid; v_org uuid; v_biz uuid;
begin
  select v into v_org from pc_ids where k='org'; select v into v_biz from pc_ids where k='biz';
  v_dr := pg_temp.pc_mk_in_transit(v_org, v_biz, 122.0);
  perform set_config('request.jwt.claims', '{}'::text, true);
  insert into public.proof_of_delivery(delivery_request_id, pod_type, storage_path, receiver_name)
    values (v_dr, 'delivery'::public.pod_type, 'pod/d.jpg', 'Rec');  -- sem location_point
  select * into r from public.confirm_delivery(v_dr);
  perform pg_temp.pc_cr('D3_skip_delivered','delivered', r.reason);
end $$;

-- D4: POD a +150m, default tol 200m -> 150<200 -> delivered.
do $$
declare r record; v_dr uuid; v_org uuid; v_biz uuid; v_dl double precision;
begin
  select v into v_org from pc_ids where k='org'; select v into v_biz from pc_ids where k='biz';
  v_dl := 123.0 + 0.05;
  v_dr := pg_temp.pc_mk_in_transit(v_org, v_biz, 123.0);
  perform set_config('request.jwt.claims', '{}'::text, true);
  insert into public.proof_of_delivery(delivery_request_id, pod_type, storage_path, receiver_name, location_point)
    values (v_dr, 'delivery'::public.pod_type, 'pod/d.jpg', 'Rec',
            st_setsrid(st_makepoint(v_dl + 0.00134778, 0.0),4326)::geography(Point,4326));  -- +150m
  select * into r from public.confirm_delivery(v_dr);
  perform pg_temp.pc_cr('D4_150m_delivered','delivered', r.reason);
end $$;

-- ============================ E. Gate de pickup POD (D3) ============================
-- E1: at_pickup->picked_up sem pickup POD -> pickup_pod_required.
do $$
declare r record; v_dr uuid; v_d uuid; v_org uuid; v_biz uuid;
begin
  select v into v_org from pc_ids where k='org'; select v into v_biz from pc_ids where k='biz';
  perform set_config('request.jwt.claims', '{}'::text, true);
  v_dr := pg_temp.pc_mk_assigned(v_org, v_biz, 130.0);
  v_d  := pg_temp.pc_driver(v_dr);
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.pc_drv_user(v_d))::text, true);  -- driver
  select * into r from public.transition_delivery(v_dr, 'driver_to_pickup');
  select * into r from public.transition_delivery(v_dr, 'at_pickup');
  perform set_config('request.jwt.claims', '{}'::text, true);  -- system: tentar picked_up sem pickup POD
  select * into r from public.transition_delivery(v_dr, 'picked_up');
  perform pg_temp.pc_cr('E1_pickup_required','pickup_pod_required', r.reason);
  perform pg_temp.pc_cr('E1_status_atpick','at_pickup', pg_temp.pc_status(v_dr));
end $$;

-- E2: submit pickup POD (driver) -> submitted, status permanece at_pickup; então picked_up ok.
do $$
declare r record; v_dr uuid; v_d uuid; v_org uuid; v_biz uuid;
begin
  select v into v_org from pc_ids where k='org'; select v into v_biz from pc_ids where k='biz';
  perform set_config('request.jwt.claims', '{}'::text, true);
  v_dr := pg_temp.pc_mk_assigned(v_org, v_biz, 131.0);
  v_d  := pg_temp.pc_driver(v_dr);
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.pc_drv_user(v_d))::text, true);  -- driver
  select * into r from public.transition_delivery(v_dr, 'driver_to_pickup');
  select * into r from public.transition_delivery(v_dr, 'at_pickup');
  select * into r from public.submit_proof_of_delivery(v_dr, 'pickup'::public.pod_type, 'pod/p.jpg', null, null, null, null, null, null);
  perform pg_temp.pc_cr('E2_submit','submitted', r.reason);
  perform pg_temp.pc_cr('E2_no_transition','at_pickup', pg_temp.pc_status(v_dr));
  perform pg_temp.pc_cr('E2_pod_pickup','t', pg_temp.pc_pod_exists(v_dr,'pickup'));
  select * into r from public.transition_delivery(v_dr, 'picked_up');
  perform pg_temp.pc_cr('E2_then_picked_up','transitioned', r.reason);
  perform pg_temp.pc_cr('E2_status','picked_up', pg_temp.pc_status(v_dr));
end $$;

-- ============================ F. confirm_delivery(p_geo_tolerance_m) (D2) ============================
-- F1: POD a +300m, confirm_delivery(id, 1) -> tol 1 -> out_of_range.
do $$
declare r record; v_dr uuid; v_org uuid; v_biz uuid; v_dl double precision;
begin
  select v into v_org from pc_ids where k='org'; select v into v_biz from pc_ids where k='biz';
  v_dl := 140.0 + 0.05;
  v_dr := pg_temp.pc_mk_in_transit(v_org, v_biz, 140.0);
  perform set_config('request.jwt.claims', '{}'::text, true);
  insert into public.proof_of_delivery(delivery_request_id, pod_type, storage_path, receiver_name, location_point)
    values (v_dr, 'delivery'::public.pod_type, 'pod/d.jpg', 'Rec',
            st_setsrid(st_makepoint(v_dl + 0.00269555, 0.0),4326)::geography(Point,4326));  -- +300m
  select * into r from public.confirm_delivery(v_dr, 1);  -- tol 1m
  perform pg_temp.pc_cr('F1_tol1_out','pod_geolocation_out_of_range', r.reason);
end $$;

-- F2: POD a +300m, confirm_delivery(id, 500) -> tol 500 -> delivered.
do $$
declare r record; v_dr uuid; v_org uuid; v_biz uuid; v_dl double precision;
begin
  select v into v_org from pc_ids where k='org'; select v into v_biz from pc_ids where k='biz';
  v_dl := 141.0 + 0.05;
  v_dr := pg_temp.pc_mk_in_transit(v_org, v_biz, 141.0);
  perform set_config('request.jwt.claims', '{}'::text, true);
  insert into public.proof_of_delivery(delivery_request_id, pod_type, storage_path, receiver_name, location_point)
    values (v_dr, 'delivery'::public.pod_type, 'pod/d.jpg', 'Rec',
            st_setsrid(st_makepoint(v_dl + 0.00269555, 0.0),4326)::geography(Point,4326));  -- +300m
  select * into r from public.confirm_delivery(v_dr, 500);  -- tol 500m
  perform pg_temp.pc_cr('F2_tol500_delivered','delivered', r.reason);
end $$;

-- ============================ G. Storage estrutural (D5) ============================
-- Validação ESTRUTURAL apenas (bucket + policy existem). RLS comportamental é DEFERIDA —
-- não exercitável via curl /database/query (Storage é API separada; endpoint DB roda como
-- management role que bypassa RLS). Não simular PASS comportamental.
do $$
declare v_bucket boolean; v_policy boolean;
begin
  select exists(select 1 from storage.buckets where id = 'pod-photos') into v_bucket;
  select exists(select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects'
                 and policyname = 'pod_photos_insert') into v_policy;
  perform pg_temp.pc_cr('G1_bucket','t', case when v_bucket then 't' else 'f' end);
  perform pg_temp.pc_cr('G2_policy','t', case when v_policy then 't' else 'f' end);
end $$;

-- ============================ Consolidated verdict ============================
-- num_failed()=0 é a autoridade (finish() emite 0 rows neste dev — Sessão 08).
select
  (select count(*) from pc_results) as total,
  (select count(*) from pc_results where pass) as passed,
  (select count(*) from pc_results where not pass) as failed,
  (select string_agg(test, ',' order by test) from pc_results where not pass) as failures;

rollback;