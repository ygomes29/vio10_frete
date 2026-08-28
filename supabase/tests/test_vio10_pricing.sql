-- test_vio10_pricing.sql — Pricing engine determinístico (Sessão 07, ADR-012).
-- Valida create_quote (system-only): álgebra D2, faixa min/max D3, seleção de regra
-- (org->global fallback) D4, atomicidade transition-first D5, capture de ator D6,
-- TTL/estado D7/D8. Cobertura:
--   T1  cotação moto standard (componentes, subtotal, customer/driver, faixa min/max,
--       delivery_quotes inserida, status quoted, quoted_at, evento quote_created c/ quote_id)
--   T2  urgent -> urgency_component aplicado
--   T3  carro vs moto -> regra diferente (base/per_km do carro)
--   T4  min_price floor (subtotal_raw < min_price -> subtotal = min_price)
--   T5  faixa não-degenerada (multipliers 0.90/1.10 -> min < alvo < max)
--   T6  driver_offer < 0 -> pricing_error
--   T7  no_pricing_rule (org sem regra própria e sem global p/ vehicle_type)
--   T8  fallback global (org sem regra própria, mas global existe)
--   T9  wrong_state (re-cotar corrida já quoted -> idempotência por estado)
--   T10 invalid_distance (0) e invalid_duration (0)
--   T11 authz: caller autenticado (auth.uid não-null) -> not_authorized; system -> ok
--   T12 distance_component ceil inteiro (distância não-múltipla de 1000m)
--
-- Executa em begin/rollback (clean-slate). Tudo roda como owner (path system,
-- auth.uid()=null); T11 injeta um sub falso via set_config para tornar auth.uid()
-- não-null (owner mantém EXECUTE em create_quote -> checa 'not_authorized' no corpo,
-- não erro de privilégio). Resultados consolidados em pr_results.

set search_path to public, extensions;
begin;

create temp table pr_ids(k text primary key, v uuid);
create temp table pr_results(test text, expected text, actual text, pass boolean);

-- cr: registra expected vs actual em pr_results.
create or replace function pg_temp.cr(t text, exp text, act text) returns void
language plpgsql as $$
begin
  insert into pr_results(test, expected, actual, pass) values (t, exp, act, exp = act);
  if exp <> act then
    raise notice 'FAIL %: exp=% act=%', t, exp, act;
  end if;
end $$;

-- ============================ SETUP (owner path) ============================
-- orgA: regras motorcycle (mult 0.90/1.10) + car. orgB: sem regra (fallback/no_rule).
-- orgD: regra motorcycle com platform_fee=500 (driver_offer<0 -> pricing_error).
-- Global: regra motorcycle apenas (sem global car) -> orgB car = no_pricing_rule.
do $$
declare
  v_orgA uuid; v_orgB uuid; v_orgD uuid; v_bizA uuid; v_bizB uuid; v_bizD uuid;
begin
  insert into public.organizations(name) values('OrgA') returning id into v_orgA;
  insert into public.organizations(name) values('OrgB') returning id into v_orgB;
  insert into public.organizations(name) values('OrgD') returning id into v_orgD;
  insert into public.businesses(organization_id,name) values(v_orgA,'BizA') returning id into v_bizA;
  insert into public.businesses(organization_id,name) values(v_orgB,'BizB') returning id into v_bizB;
  insert into public.businesses(organization_id,name) values(v_orgD,'BizD') returning id into v_bizD;

  -- orgA motorcycle: base=500 per_km=100 urgency=200 min_price=800 fee=120 mult 0.90/1.10
  insert into public.pricing_rules
    (organization_id, vehicle_type, base_cents, per_km_cents, per_minute_cents,
     urgency_add_cents, min_price_cents, platform_fee_cents, min_multiplier, max_multiplier, is_active)
  values (v_orgA,'motorcycle',500,100,10,200,800,120,0.90,1.10,true);

  -- orgA car: base=700 per_km=150 urgency=300 min_price=1000 fee=150 mult 1.0/1.0
  insert into public.pricing_rules
    (organization_id, vehicle_type, base_cents, per_km_cents, per_minute_cents,
     urgency_add_cents, min_price_cents, platform_fee_cents, min_multiplier, max_multiplier, is_active)
  values (v_orgA,'car',700,150,15,300,1000,150,1.0,1.0,true);

  -- global motorcycle (org null): base=400 per_km=80 urgency=150 min_price=600 fee=100
  insert into public.pricing_rules
    (organization_id, vehicle_type, base_cents, per_km_cents, per_minute_cents,
     urgency_add_cents, min_price_cents, platform_fee_cents, min_multiplier, max_multiplier, is_active)
  values (null,'motorcycle',400,80,8,150,600,100,1.0,1.0,true);

  -- orgD motorcycle: base=100 fee=500 -> subtotal 100, driver=100-500 <0 -> pricing_error
  insert into public.pricing_rules
    (organization_id, vehicle_type, base_cents, per_km_cents, per_minute_cents,
     urgency_add_cents, min_price_cents, platform_fee_cents, min_multiplier, max_multiplier, is_active)
  values (v_orgD,'motorcycle',100,0,0,0,0,500,1.0,1.0,true);

  insert into pr_ids(k,v) values
    ('orgA',v_orgA),('orgB',v_orgB),('orgD',v_orgD),
    ('bizA',v_bizA),('bizB',v_bizB),('bizD',v_bizD);
end $$;

-- mk_draft: cria delivery_request em draft (system-scoped, auth.uid null).
create or replace function pg_temp.mk_draft(p_org uuid, p_biz uuid, p_vehicle text, p_priority text)
returns uuid language plpgsql as $$
declare r record; v_items jsonb := '[{"description":"cx","quantity":1}]'::jsonb;
begin
  select * into r from public.create_delivery_request(
    p_org, p_biz, null,
    'Pickup', -23.5000, -46.0000, 'PN', '555',
    'Delivery', -23.5500, -46.0500, 'DN', '666',
    p_vehicle::public.vehicle_type, p_priority::public.delivery_priority,
    null, 'dashboard', null, null, null, v_items, null);
  return r.delivery_request_id;
end $$;

-- Cria as delivery_requests draft (system path).
do $$
declare
  v_orgA uuid := (select v from pr_ids where k='orgA');
  v_orgB uuid := (select v from pr_ids where k='orgB');
  v_orgD uuid := (select v from pr_ids where k='orgD');
  v_bizA uuid := (select v from pr_ids where k='bizA');
  v_bizB uuid := (select v from pr_ids where k='bizB');
  v_bizD uuid := (select v from pr_ids where k='bizD');
begin
  insert into pr_ids(k,v) values
    ('dr1', pg_temp.mk_draft(v_orgA,v_bizA,'motorcycle','standard')),  -- T1/T5/T9
    ('dr2', pg_temp.mk_draft(v_orgA,v_bizA,'motorcycle','urgent')),    -- T2
    ('dr3', pg_temp.mk_draft(v_orgA,v_bizA,'car','standard')),         -- T3
    ('dr4', pg_temp.mk_draft(v_orgA,v_bizA,'motorcycle','standard')),  -- T4 min_price floor
    ('dr5', pg_temp.mk_draft(v_orgA,v_bizA,'motorcycle','standard')),  -- T12 ceil
    ('dr6', pg_temp.mk_draft(v_orgB,v_bizB,'car','standard')),         -- T7 no_pricing_rule
    ('dr7', pg_temp.mk_draft(v_orgB,v_bizB,'motorcycle','standard')),  -- T8 fallback global
    ('dr8', pg_temp.mk_draft(v_orgA,v_bizA,'motorcycle','standard')),  -- T10/T11
    ('dr9', pg_temp.mk_draft(v_orgD,v_bizD,'motorcycle','standard'));  -- T6 pricing_error
end $$;

-- q: lê uma coluna (texto) da quote mais recente de uma delivery.
create or replace function pg_temp.q(p_dr uuid, p_col text) returns text
language plpgsql as $$
declare v text;
begin
  execute format('select %I::text from public.delivery_quotes where delivery_request_id=$1 order by created_at desc limit 1', p_col)
    into v using p_dr;
  return v;
end $$;

-- ============================ T1: cotação moto standard ============================
do $$
declare r public.delivery_quotes%rowtype; v_ok boolean; v_reason text; v_qid uuid;
  v_dr uuid := (select v from pr_ids where k='dr1');
  v_evqid text; v_status text; v_qat text;
begin
  select ok, reason, quote_id into v_ok, v_reason, v_qid
    from public.create_quote(v_dr, 10000, 600);
  perform pg_temp.cr('T1_ok','t', case when v_ok then 't' else 'f' end);
  perform pg_temp.cr('T1_reason','quoted', coalesce(v_reason,''));
  -- snapshot
  select * into r from public.delivery_quotes where delivery_request_id=v_dr order by created_at desc limit 1;
  perform pg_temp.cr('T1_base','500', r.base_cents::text);
  perform pg_temp.cr('T1_distance_comp','1000', r.distance_component_cents::text);
  perform pg_temp.cr('T1_vehicle_comp','0', r.vehicle_component_cents::text);
  perform pg_temp.cr('T1_urgency_comp','0', r.urgency_component_cents::text);
  perform pg_temp.cr('T1_dynamic_comp','0', r.dynamic_component_cents::text);
  perform pg_temp.cr('T1_subtotal','1500', r.subtotal_cents::text);
  perform pg_temp.cr('T1_platform_fee','120', r.platform_fee_cents::text);
  perform pg_temp.cr('T1_customer','1620', r.customer_price_cents::text);
  perform pg_temp.cr('T1_driver','1380', r.driver_offer_cents::text);
  perform pg_temp.cr('T1_min_customer','1458', r.min_customer_price_cents::text);
  perform pg_temp.cr('T1_max_customer','1782', r.max_customer_price_cents::text);
  perform pg_temp.cr('T1_min_driver','1242', r.min_driver_offer_cents::text);
  perform pg_temp.cr('T1_max_driver','1518', r.max_driver_offer_cents::text);
  perform pg_temp.cr('T1_distance_meters','10000', r.distance_meters::text);
  perform pg_temp.cr('T1_duration_seconds','600', r.duration_seconds::text);
  perform pg_temp.cr('T1_quote_status','pending', r.status::text);
  -- delivery transitou para quoted e quoted_at setado
  select status::text, case when quoted_at is not null then 't' else 'f' end into v_status, v_qat from public.delivery_requests where id=v_dr;
  perform pg_temp.cr('T1_dr_status','quoted', v_status);
  perform pg_temp.cr('T1_quoted_at_set','t', v_qat);
  -- evento quote_created presente e metadata.quote_id bate com o id da quote
  select metadata->>'quote_id' into v_evqid from public.delivery_events
   where delivery_request_id=v_dr and event_type='quote_created' order by created_at desc limit 1;
  perform pg_temp.cr('T1_event_quote_id', r.id::text, coalesce(v_evqid,''));
end $$;

-- ============================ T2: urgent -> urgency_component ============================
do $$
declare r public.delivery_quotes%rowtype; v_ok boolean; v_reason text;
  v_dr uuid := (select v from pr_ids where k='dr2');
begin
  select ok, reason into v_ok, v_reason from public.create_quote(v_dr, 10000, 600);
  perform pg_temp.cr('T2_ok','t', case when v_ok then 't' else 'f' end);
  select * into r from public.delivery_quotes where delivery_request_id=v_dr order by created_at desc limit 1;
  perform pg_temp.cr('T2_urgency_comp','200', r.urgency_component_cents::text);
  perform pg_temp.cr('T2_subtotal','1700', r.subtotal_cents::text);
  perform pg_temp.cr('T2_customer','1820', r.customer_price_cents::text);
  perform pg_temp.cr('T2_driver','1580', r.driver_offer_cents::text);
end $$;

-- ============================ T3: carro vs moto (regra diferente) ============================
do $$
declare r public.delivery_quotes%rowtype; v_ok boolean; v_reason text;
  v_dr uuid := (select v from pr_ids where k='dr3');
begin
  select ok, reason into v_ok, v_reason from public.create_quote(v_dr, 10000, 600);
  perform pg_temp.cr('T3_ok','t', case when v_ok then 't' else 'f' end);
  select * into r from public.delivery_quotes where delivery_request_id=v_dr order by created_at desc limit 1;
  perform pg_temp.cr('T3_base','700', r.base_cents::text);          -- regra do carro
  perform pg_temp.cr('T3_distance_comp','1500', r.distance_component_cents::text);
  perform pg_temp.cr('T3_subtotal','2200', r.subtotal_cents::text);
  perform pg_temp.cr('T3_customer','2350', r.customer_price_cents::text);
  perform pg_temp.cr('T3_driver','2050', r.driver_offer_cents::text);
end $$;

-- ============================ T4: min_price floor ============================
-- distance=1000m -> subtotal_raw=600 < min_price 800 -> subtotal=800
do $$
declare r public.delivery_quotes%rowtype; v_ok boolean; v_reason text;
  v_dr uuid := (select v from pr_ids where k='dr4');
begin
  select ok, reason into v_ok, v_reason from public.create_quote(v_dr, 1000, 300);
  perform pg_temp.cr('T4_ok','t', case when v_ok then 't' else 'f' end);
  select * into r from public.delivery_quotes where delivery_request_id=v_dr order by created_at desc limit 1;
  perform pg_temp.cr('T4_distance_comp','100', r.distance_component_cents::text);
  perform pg_temp.cr('T4_subtotal','800', r.subtotal_cents::text);  -- floor
  perform pg_temp.cr('T4_customer','920', r.customer_price_cents::text);
  perform pg_temp.cr('T4_driver','680', r.driver_offer_cents::text);
end $$;

-- ============================ T5: faixa não-degenerada (dr1) ============================
do $$
declare b boolean;
begin
  select min_customer_price_cents < customer_price_cents
         and customer_price_cents < max_customer_price_cents
         and min_driver_offer_cents < driver_offer_cents
         and driver_offer_cents < max_driver_offer_cents
    into b
    from public.delivery_quotes where delivery_request_id=(select v from pr_ids where k='dr1')
    order by created_at desc limit 1;
  perform pg_temp.cr('T5_faixa_nao_degenerada','t', case when b then 't' else 'f' end);
end $$;

-- ============================ T6: driver_offer < 0 -> pricing_error ============================
do $$
declare v_ok boolean; v_reason text;
  v_dr uuid := (select v from pr_ids where k='dr9');
begin
  select ok, reason into v_ok, v_reason from public.create_quote(v_dr, 1000, 300);
  perform pg_temp.cr('T6_ok','f', case when v_ok then 't' else 'f' end);
  perform pg_temp.cr('T6_reason','pricing_error', coalesce(v_reason,''));
  -- nenhuma quote inserida, delivery continua draft
  perform pg_temp.cr('T6_no_quote','0',
    (select count(*)::text from public.delivery_quotes where delivery_request_id=v_dr));
  perform pg_temp.cr('T6_still_draft','draft',
    (select status::text from public.delivery_requests where id=v_dr));
end $$;

-- ============================ T7: no_pricing_rule (orgB car, sem global car) ============================
do $$
declare v_ok boolean; v_reason text;
  v_dr uuid := (select v from pr_ids where k='dr6');
begin
  select ok, reason into v_ok, v_reason from public.create_quote(v_dr, 10000, 600);
  perform pg_temp.cr('T7_ok','f', case when v_ok then 't' else 'f' end);
  perform pg_temp.cr('T7_reason','no_pricing_rule', coalesce(v_reason,''));
  perform pg_temp.cr('T7_still_draft','draft',
    (select status::text from public.delivery_requests where id=v_dr));
end $$;

-- ============================ T8: fallback global (orgB moto -> global moto) ============================
do $$
declare r public.delivery_quotes%rowtype; v_ok boolean; v_reason text;
  v_dr uuid := (select v from pr_ids where k='dr7');
begin
  select ok, reason into v_ok, v_reason from public.create_quote(v_dr, 10000, 600);
  perform pg_temp.cr('T8_ok','t', case when v_ok then 't' else 'f' end);
  select * into r from public.delivery_quotes where delivery_request_id=v_dr order by created_at desc limit 1;
  perform pg_temp.cr('T8_base','400', r.base_cents::text);          -- regra global
  perform pg_temp.cr('T8_distance_comp','800', r.distance_component_cents::text);
  perform pg_temp.cr('T8_subtotal','1200', r.subtotal_cents::text);
  perform pg_temp.cr('T8_customer','1300', r.customer_price_cents::text);
  perform pg_temp.cr('T8_driver','1100', r.driver_offer_cents::text);
end $$;

-- ============================ T9: wrong_state (re-cotar dr1 já quoted) ============================
do $$
declare v_ok boolean; v_reason text;
  v_dr uuid := (select v from pr_ids where k='dr1');
begin
  select ok, reason into v_ok, v_reason from public.create_quote(v_dr, 10000, 600);
  perform pg_temp.cr('T9_ok','f', case when v_ok then 't' else 'f' end);
  perform pg_temp.cr('T9_reason','wrong_state', coalesce(v_reason,''));
end $$;

-- ============================ T10: invalid_distance / invalid_duration ============================
do $$
declare v_ok boolean; v_reason text;
  v_dr uuid := (select v from pr_ids where k='dr8');
begin
  select ok, reason into v_ok, v_reason from public.create_quote(v_dr, 0, 600);
  perform pg_temp.cr('T10a_invalid_distance','invalid_distance', coalesce(v_reason,''));
  select ok, reason into v_ok, v_reason from public.create_quote(v_dr, 1000, 0);
  perform pg_temp.cr('T10b_invalid_duration','invalid_duration', coalesce(v_reason,''));
  -- ainda draft (inputs inválidos não transicionam)
  perform pg_temp.cr('T10c_still_draft','draft',
    (select status::text from public.delivery_requests where id=v_dr));
end $$;

-- ============================ T11: authz (auth.uid não-null -> not_authorized; system -> ok) ============================
do $$
declare v_ok boolean; v_reason text; v_qid uuid;
  v_dr uuid := (select v from pr_ids where k='dr8');
  v_fake uuid := gen_random_uuid();
begin
  -- injeta sub falso: auth.uid() não-null -> create_quote retorna not_authorized
  -- (owner tem EXECUTE, então é a checagem do corpo, não erro de privilégio).
  perform set_config('request.jwt.claims', json_build_object('sub', v_fake)::text, true);
  select ok, reason into v_ok, v_reason from public.create_quote(v_dr, 10000, 600);
  perform pg_temp.cr('T11a_authz_rejected','f', case when v_ok then 't' else 'f' end);
  perform pg_temp.cr('T11a_reason','not_authorized', coalesce(v_reason,''));
  -- reseta JWT -> system path (auth.uid null) -> ok
  perform set_config('request.jwt.claims', '{}'::text, true);
  select ok, reason, quote_id into v_ok, v_reason, v_qid from public.create_quote(v_dr, 10000, 600);
  perform pg_temp.cr('T11b_system_ok','t', case when v_ok then 't' else 'f' end);
  perform pg_temp.cr('T11b_reason','quoted', coalesce(v_reason,''));
end $$;

-- ============================ T12: distance_component ceil inteiro (1001m) ============================
do $$
declare r public.delivery_quotes%rowtype; v_ok boolean; v_reason text;
  v_dr uuid := (select v from pr_ids where k='dr5');
begin
  select ok, reason into v_ok, v_reason from public.create_quote(v_dr, 1001, 300);
  perform pg_temp.cr('T12_ok','t', case when v_ok then 't' else 'f' end);
  select * into r from public.delivery_quotes where delivery_request_id=v_dr order by created_at desc limit 1;
  -- (100 * 1001 + 999)/1000 = 101099/1000 = 101 (ceil de 100.1)
  perform pg_temp.cr('T12_distance_comp_ceil','101', r.distance_component_cents::text);
end $$;

-- ============================ Resultado consolidado ============================
select
  (select count(*) from pr_results) as total,
  (select count(*) from pr_results where pass) as passed,
  (select count(*) from pr_results where not pass) as failed,
  (select string_agg(test, ', ') from pr_results where not pass) as failures;

rollback;