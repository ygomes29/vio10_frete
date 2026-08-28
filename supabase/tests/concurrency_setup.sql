-- concurrency_setup.sql — Sessão 10 (ADR-015). Setup ONE-TIME para o harness de
-- concorrência real: schema `harness` + helpers + org/pricing. Os CENÁRIOS (A/B/C) são
-- rebuildados por execução (concurrency_rebuild.sql) com tags run-sufixadas para emails
-- únicos (auth.users.email é unique). COMMIT necessário — curls paralelos rodam em
-- conexões separadas e precisam ver os dados.
set search_path to public, extensions, pg_catalog;
create schema if not exists harness;
drop table if exists harness.state;
drop table if exists harness.org;
create table harness.state(tag text primary key, ids jsonb);
create table harness.org(id int primary key default 1, org_id uuid, biz_id uuid);

create or replace function harness.mk_driver(
  p_email text, p_full text, p_phone text, p_lng double precision
) returns uuid language plpgsql set search_path = public, extensions, pg_catalog as $$
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

-- mk_scenario: 1 cenário (2 drivers + delivery searching + round + 2 offers accept).
create or replace function harness.mk_scenario(
  p_tag text, p_org uuid, p_biz uuid,
  p_pickup_lng double precision, p_d1_lng double precision, p_d2_lng double precision
) returns jsonb language plpgsql set search_path = public, extensions, pg_catalog as $$
declare
  v_d1 uuid; v_d2 uuid; v_dr uuid; r record; v_round uuid; v_o1 uuid; v_o2 uuid;
begin
  v_d1 := harness.mk_driver(p_tag||'-d1@h.local', p_tag||' D1', '555-0001', p_d1_lng);
  v_d2 := harness.mk_driver(p_tag||'-d2@h.local', p_tag||' D2', '555-0002', p_d2_lng);
  select * into r from public.create_delivery_request(
    p_org, p_biz, null,
    'Pickup', 0.0, p_pickup_lng, 'PN','555','Delivery', 0.0, p_pickup_lng + 0.05, 'DN','666',
    'motorcycle'::public.vehicle_type, 'standard'::public.delivery_priority,
    null, 'dashboard', null, null, null, '[{"description":"cx","quantity":1}]'::jsonb, null);
  v_dr := r.delivery_request_id;
  select * into r from public.create_quote(v_dr, 10000, 600);
  select * into r from public.confirm_quote(v_dr);
  -- open_dispatch_round(delivery, radius_m=10000, max_candidates=5, driver_offer=1500, window=120s)
  select * into r from public.open_dispatch_round(v_dr, 10000, 5, 1500, 120);
  v_round := r.round_id;
  select id into v_o1 from public.delivery_offers where dispatch_round_id = v_round and driver_id = v_d1;
  select id into v_o2 from public.delivery_offers where dispatch_round_id = v_round and driver_id = v_d2;
  perform public.respond_to_offer(v_o1, v_d1, 'accept'::public.bid_response_type, null);
  perform public.respond_to_offer(v_o2, v_d2, 'accept'::public.bid_response_type, null);
  return jsonb_build_object(
    'tag', p_tag, 'delivery_id', v_dr, 'round_id', v_round,
    'offer1_id', v_o1, 'offer2_id', v_o2,
    'driver1_id', v_d1, 'driver2_id', v_d2);
end $$;

-- Org + pricing (1x).
do $$
declare v_org uuid; v_biz uuid; v_u uuid;
begin
  insert into public.organizations(name) values('HOrg') returning id into v_org;
  insert into public.businesses(organization_id,name) values(v_org,'HBiz') returning id into v_biz;
  v_u := gen_random_uuid(); insert into auth.users(id,email) values(v_u,'hu@h.local');
  insert into public.organization_memberships(user_id,organization_id,role)
    values(v_u,v_org,'business_user');
  insert into public.pricing_rules
    (organization_id, vehicle_type, base_cents, per_km_cents, per_minute_cents,
     urgency_add_cents, min_price_cents, platform_fee_cents, is_active)
  values (v_org,'motorcycle',500,100,10,200,800,120,true);
  insert into harness.org(id, org_id, biz_id) values (1, v_org, v_biz);
end $$;

select org_id, biz_id from harness.org;