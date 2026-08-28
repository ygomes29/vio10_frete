-- test_vio10_invariants.sql
-- Testes das invariantes fundamentais do banco ViO10 (pgTAP).
-- PostGIS no schema `extensions`; runner de testes não o inclui no search_path.
set search_path to public, extensions;
-- Executar com: supabase db test (local) ou contra projeto dev via execute_sql.
-- Requer PostGIS (schema extensions) e pgTAP.

select plan(12);

-- ============================================================================
-- Helpers (rolam back ao fim do teste; cada arquivo roda em sua própria txn).
-- ============================================================================
create temp table if not exists vio10_ids (k text primary key, v text) on commit drop;

create or replace function _vio10_mk_user(p_email text) returns uuid
language plpgsql as $$
declare u uuid;
begin
  u := gen_random_uuid();
  -- Email único por execução (evita conflito de unique com sobras de runs anteriores).
  insert into auth.users (id, email) values (u, split_part(p_email,'@',1) || '_' || gen_random_uuid()::text || '@' || coalesce(split_part(p_email,'@',2),'t.local')) on conflict do nothing;
  insert into public.profiles (id) values (u) on conflict do nothing;
  return u;
end $$;

-- Cria org+business+location+2 drivers+1 delivery em searching_driver e popula vio10_ids.
create or replace function _vio10_setup() returns uuid
language plpgsql as $$
declare
  v_org uuid; v_biz uuid; v_loc uuid; v_u1 uuid; v_u2 uuid; v_d1 uuid; v_d2 uuid; v_dr uuid;
  v_pickup geography(Point,4326);
begin
  v_pickup := ST_SetSRID(ST_MakePoint(-43.8589, -22.9702), 4326)::geography(Point,4326);
  insert into public.organizations (name) values ('Test Org') returning id into v_org;
  insert into public.businesses (organization_id, name) values (v_org, 'Test Biz') returning id into v_biz;
  insert into public.business_locations (business_id, address, latitude, longitude, point)
    values (v_biz, 'Rua Teste 1', -22.9702, -43.8589, v_pickup) returning id into v_loc;
  v_u1 := _vio10_mk_user('d1@t.local'); v_u2 := _vio10_mk_user('d2@t.local');
  insert into public.drivers (user_id, full_name, phone, account_status, current_availability_status)
    values (v_u1,'Driver One','11900000001','active','available') returning id into v_d1;
  insert into public.drivers (user_id, full_name, phone, account_status, current_availability_status)
    values (v_u2,'Driver Two','11900000002','active','available') returning id into v_d2;
  -- driver_locations: posição ATUAL (1:1). Necessário para T11 (consulta por raio).
  insert into public.driver_locations (driver_id, position, captured_at) values
    (v_d1, ST_SetSRID(ST_MakePoint(-43.8589, -22.9730),4326)::geography(Point,4326), now()),
    (v_d2, ST_SetSRID(ST_MakePoint(-43.8200, -22.9702),4326)::geography(Point,4326), now());
  insert into public.delivery_requests
    (organization_id, business_id, business_location_id,
     pickup_address, pickup_latitude, pickup_longitude, pickup_point, pickup_contact_phone,
     delivery_address, delivery_latitude, delivery_longitude, delivery_point, delivery_contact_phone,
     vehicle_required, status)
  values (v_org, v_biz, v_loc, 'Coleta', -22.9702, -43.8589, v_pickup, '11990000001',
    'Entrega', -22.9750, -43.8600,
    ST_SetSRID(ST_MakePoint(-43.8600, -22.9750),4326)::geography(Point,4326), '11990000002',
    'motorcycle', 'searching_driver')
  returning id into v_dr;
  insert into vio10_ids values ('org',v_org::text),('biz',v_biz::text),
    ('driver1',v_d1::text),('driver2',v_d2::text),('delivery',v_dr::text);
  return v_dr;
end $$;

-- Cria round aberta + offer (pending) para um driver. Armazena 'round'.
create or replace function _vio10_mk_offer(p_driver uuid) returns uuid
language plpgsql as $$
declare v_dr uuid; v_round uuid; v_offer uuid;
begin
  select v::uuid from vio10_ids where k='delivery' into v_dr;
  insert into public.dispatch_rounds
    (delivery_request_id, round_number, search_radius_m, max_candidates, driver_offer_cents, expires_at)
  values (v_dr, (select coalesce(max(round_number),0)+1 from public.dispatch_rounds where delivery_request_id=v_dr),
    2000, 5, 1000, now() + interval '5 minutes')
  returning id into v_round;
  insert into public.delivery_offers
    (delivery_request_id, dispatch_round_id, driver_id, driver_offer_cents, expires_at)
  values (v_dr, v_round, p_driver, 1000, now() + interval '5 minutes')
  returning id into v_offer;
  insert into vio10_ids values ('round', v_round::text) on conflict (k) do update set v=excluded.v;
  return v_offer;
end $$;

-- ============================================================================
-- Setup inicial (compartilhado).
-- ============================================================================
select _vio10_setup();

-- ============================================================================
-- T1: não permite duas assignments ativas na mesma delivery.
-- ============================================================================
insert into public.delivery_assignments (delivery_request_id, driver_id, status)
  select v::uuid, (select v::uuid from vio10_ids where k='driver1'), 'active'
  from vio10_ids where k='delivery';
select throws_ok(
  $$ insert into public.delivery_assignments (delivery_request_id, driver_id, status)
     select v::uuid, (select v::uuid from vio10_ids where k='driver2'), 'active'
     from vio10_ids where k='delivery' $$,
  '23505'::char(5),
  null,
  'T1: segunda assignment ativa rejeitada (partial unique index)'
);

-- ============================================================================
-- T2: permite histórico (encerrada) + nova ativa (reatribuição).
-- ============================================================================
update public.delivery_assignments set status='superseded', ended_at=now()
  where delivery_request_id=(select v::uuid from vio10_ids where k='delivery') and status='active';
select lives_ok(
  $$ insert into public.delivery_assignments (delivery_request_id, driver_id, status)
     select v::uuid, (select v::uuid from vio10_ids where k='driver2'), 'active'
     from vio10_ids where k='delivery' $$,
  'T2: nova assignment ativa após superseder a anterior é permitida'
);
truncate public.delivery_assignments;
update public.delivery_requests set status='searching_driver'
  where id=(select v::uuid from vio10_ids where k='delivery');

-- ============================================================================
-- T3: webhook repetido (source, external_id) não duplica.
-- ============================================================================
insert into public.webhook_events (source, external_id, event_type) values ('datacrazy','ext-1','msg');
select throws_ok(
  $$ insert into public.webhook_events (source, external_id, event_type) values ('datacrazy','ext-1','msg') $$,
  '23505'::char(5),
  null,
  'T3: webhook repetido é deduplicado'
);

-- ============================================================================
-- T4: idempotency_key repetida é tratada.
-- ============================================================================
insert into public.integration_events (source, idempotency_key, event_type) values ('backend','idem-1','create_delivery');
select throws_ok(
  $$ insert into public.integration_events (source, idempotency_key, event_type) values ('backend','idem-1','create_delivery') $$,
  '23505'::char(5),
  null,
  'T4: idempotency_key repetida é rejeitada na entrada'
);

-- ============================================================================
-- T5: bid não pode ser associado a offer de outro driver (FK composto).
-- ============================================================================
select _vio10_mk_offer((select v::uuid from vio10_ids where k='driver1'));
select throws_ok(
  $$ insert into public.bids
       (delivery_offer_id, driver_id, delivery_request_id, response_type, bid_amount_cents)
     select o.id, (select v::uuid from vio10_ids where k='driver2'),
            o.delivery_request_id, 'accept', o.driver_offer_cents
     from public.delivery_offers o
     join vio10_ids i on i.k='driver1'
     where o.driver_id = i.v::uuid
     limit 1 $$,
  '23503'::char(5),
  null,
  'T5: bid para offer de outro driver rejeitado (FK composto offer/driver)'
);

-- ============================================================================
-- T6: oferta expirada rejeitada por respond_to_offer.
-- ============================================================================
do $$
declare v_exp uuid;
begin
  insert into public.delivery_offers
    (delivery_request_id, dispatch_round_id, driver_id, driver_offer_cents, expires_at, status)
  select v_dr, (select v::uuid from vio10_ids where k='round'),
         (select v::uuid from vio10_ids where k='driver2'), 1000, now()-interval '1 minute','pending'
  from (select v::uuid from vio10_ids where k='delivery') t(v_dr)
  returning id into v_exp;
  insert into vio10_ids values ('exp_offer', v_exp::text) on conflict (k) do update set v=excluded.v;
end $$;
select is(
  (select ok from public.respond_to_offer(
     (select v::uuid from vio10_ids where k='exp_offer'),
     (select v::uuid from vio10_ids where k='driver2'),
     'accept', null, 'idem-exp')),
  false,
  'T6: respond_to_offer rejeita oferta expirada (ok=false)'
);

-- ============================================================================
-- T7: round inválida (round_number <= 0) rejeitada.
-- ============================================================================
select throws_ok(
  $$ insert into public.dispatch_rounds
       (delivery_request_id, round_number, search_radius_m, max_candidates, driver_offer_cents, expires_at)
     select v::uuid, 0, 1000, 3, 1000, now()+interval '5 min' from vio10_ids where k='delivery' $$,
  '23514'::char(5),
  null,
  'T7: round_number <= 0 rejeitado (check)'
);

-- ============================================================================
-- T8: delivery status inválido é impossível.
-- ============================================================================
select throws_ok(
  $$ update public.delivery_requests set status='bogus'::delivery_status
     where id=(select v::uuid from vio10_ids where k='delivery') $$,
  '22P02'::char(5),
  null,
  'T8: status de corrida inválido rejeitado (enum)'
);

-- ============================================================================
-- T9: foreign keys críticas funcionam.
-- ============================================================================
select throws_ok(
  $$ insert into public.delivery_requests
     (organization_id, business_id, pickup_address, pickup_latitude, pickup_longitude, pickup_point,
      pickup_contact_phone, delivery_address, delivery_latitude, delivery_longitude, delivery_point,
      delivery_contact_phone, vehicle_required)
     values ('00000000-0000-0000-0000-000000000000','00000000-0000-0000-0000-000000000000',
       'x',0,0,ST_SetSRID(ST_MakePoint(0,0),4326)::geography(Point,4326),'0',
       'y',0,0,ST_SetSRID(ST_MakePoint(0,0),4326)::geography(Point,4326),'0','motorcycle') $$,
  '23503'::char(5),
  null,
  'T9: FK org/business inexistente rejeitada'
);

-- ============================================================================
-- T10: RLS default deny — role com SELECT concedido vê 0 linhas (RLS filtra).
-- ============================================================================
-- T10 roda num DO block porque o runner server-side (Management API) executa como
-- um role com bypassrls; para provar default-deny via RLS precisamos alternar para
-- um role SEM bypass e COM SELECT concedido. O runner é membro dos roles Supabase
-- (anon/authenticated/...) mas nenhum deles tem SELECT (0014 revogou tudo) e
-- service_role bypassa RLS. Criamos um role próprio, concedemos SELECT, tornamos o
-- runner membro dele (para permitir SET ROLE), contamos sob aquele role e voltamos.
-- `perform is()` acumula o resultado no pgTAP via side-effect (independente de
-- capturar o texto), funcionando tanto no runner server-side quanto num test db local.
do $$
declare
  u text;
  n bigint;
begin
  u := current_user;
  if not exists (select 1 from pg_roles where rolname='vio10_test_user') then
    create role vio10_test_user;
  end if;
  -- Torna o runner membro do role de teste => libera SET ROLE.
  execute format('grant vio10_test_user to %I', u);
  grant usage on schema public to vio10_test_user;
  grant select on public.organizations to vio10_test_user;
  set local role vio10_test_user;
  -- RLS habilitado sem policies => role autorizado vê 0 linhas (default deny).
  select count(*) into n from public.organizations;
  reset role;
  perform is(n, 0::bigint, 'T10: RLS default deny — role autorizada vê 0 linhas (sem policy)');
end $$;

-- ============================================================================
-- T11 (geoespacial): consultar entregadores disponíveis dentro de um raio.
-- ============================================================================
update public.driver_locations
  set position = ST_SetSRID(ST_MakePoint(-43.8589, -22.9730),4326)::geography(Point,4326), captured_at = now()
  where driver_id=(select v::uuid from vio10_ids where k='driver1');
update public.driver_locations
  set position = ST_SetSRID(ST_MakePoint(-43.8200, -22.9702),4326)::geography(Point,4326), captured_at = now()
  where driver_id=(select v::uuid from vio10_ids where k='driver2');
select is(
  (select count(*) from public.driver_locations dl
   join public.drivers d on d.id = dl.driver_id
   where d.current_availability_status='available'
     and ST_DWithin(dl.position, ST_SetSRID(ST_MakePoint(-43.8589,-22.9702),4326)::geography(Point,4326), 2000)),
  1::bigint,
  'T11: consulta por raio retorna apenas o entregador próximo (PostGIS ST_DWithin)'
);

-- ============================================================================
-- T12: delivery_events é imutável (append-only) — UPDATE e DELETE bloqueados.
-- ============================================================================
insert into public.delivery_events (delivery_request_id, event_type, to_status)
  select v::uuid, 'delivery_created'::delivery_event_type, 'draft'::delivery_status
  from vio10_ids where k='delivery';
select throws_ok(
  $$ update public.delivery_events set event_type='delivered'::delivery_event_type
     where delivery_request_id=(select v::uuid from vio10_ids where k='delivery') $$,
  null,
  'T12a: UPDATE em delivery_events bloqueado (imutável)'
);
select throws_ok(
  $$ delete from public.delivery_events
     where delivery_request_id=(select v::uuid from vio10_ids where k='delivery') $$,
  null,
  'T12b: DELETE em delivery_events bloqueado (imutável)'
);

select * from finish();