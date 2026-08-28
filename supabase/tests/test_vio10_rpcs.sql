-- test_vio10_rpcs.sql
-- Testes de comportamento das RPCs do ViO10 (pgTAP). Autocontido: cada teste cria seu
-- PostGIS no schema `extensions`; runner de testes não o inclui no search_path.
set search_path to public, extensions;
-- próprio dataset via _rpc_setup(label, status). Cobre respond_to_offer, claim_delivery,
-- transition_delivery, set_driver_availability, R16 (cross-round) e imutabilidade indireta.

select plan(48);

-- Tabelas temporárias para capturar retorno das RPCs.
create temp table rpc_res(ok boolean, reason text, bid_id uuid) on commit drop;
create temp table claim_res(won boolean, reason text) on commit drop;
create temp table trans_res(ok boolean, reason text) on commit drop;
create temp table rpc_ids(k text primary key, v text) on commit drop;

-- Cria auth.users + profile. Email randômico para ser único entre re-runs.
create or replace function _rpc_mk_user() returns uuid
language plpgsql as $$
declare u uuid;
begin
  u := gen_random_uuid();
  insert into auth.users (id, email) values (u, 'u'||replace(u::text,'-','')||'@t.local') on conflict do nothing;
  insert into public.profiles (id) values (u) on conflict do nothing;
  return u;
end $$;

-- Cria org, biz, 2 drivers (com location), 1 delivery em p_status, 1 round com 2 offers
-- (o1=driver1 pending, o2=driver2 pending). Ids em rpc_ids com prefixo p_label.
create or replace function _rpc_setup(p_label text, p_status delivery_status default 'searching_driver') returns void
language plpgsql as $$
declare
  v_org uuid; v_biz uuid; v_u1 uuid; v_u2 uuid; v_d1 uuid; v_d2 uuid; v_dr uuid;
  v_round uuid; v_o1 uuid; v_o2 uuid; v_pt geography(Point,4326);
begin
  v_pt := ST_SetSRID(ST_MakePoint(-43.8589,-22.9702),4326)::geography(Point,4326);
  insert into public.organizations(name) values('Org '||p_label) returning id into v_org;
  insert into public.businesses(organization_id,name) values(v_org,'Biz '||p_label) returning id into v_biz;
  v_u1 := _rpc_mk_user(); v_u2 := _rpc_mk_user();
  insert into public.drivers(user_id,full_name,phone,account_status,current_availability_status)
    values(v_u1,'D1','1','active','available') returning id into v_d1;
  insert into public.drivers(user_id,full_name,phone,account_status,current_availability_status)
    values(v_u2,'D2','2','active','available') returning id into v_d2;
  insert into public.driver_locations(driver_id,position,captured_at) values (v_d1, v_pt, now()), (v_d2, v_pt, now());
  insert into public.delivery_requests(organization_id,business_id,
    pickup_address,pickup_latitude,pickup_longitude,pickup_point,pickup_contact_phone,
    delivery_address,delivery_latitude,delivery_longitude,delivery_point,delivery_contact_phone,
    vehicle_required,status)
  values(v_org,v_biz,'coleta',-22.9702,-43.8589,v_pt,'1',
    'entrega',-22.9750,-43.8600,ST_SetSRID(ST_MakePoint(-43.8600,-22.9750),4326)::geography(Point,4326),'1',
    'motorcycle',p_status) returning id into v_dr;
  insert into public.dispatch_rounds(delivery_request_id,round_number,search_radius_m,max_candidates,driver_offer_cents,expires_at)
    values(v_dr,1,2000,5,1000,now()+interval '5 min') returning id into v_round;
  insert into public.delivery_offers(delivery_request_id,dispatch_round_id,driver_id,driver_offer_cents,expires_at)
    values(v_dr,v_round,v_d1,1000,now()+interval '5 min') returning id into v_o1;
  insert into public.delivery_offers(delivery_request_id,dispatch_round_id,driver_id,driver_offer_cents,expires_at)
    values(v_dr,v_round,v_d2,1000,now()+interval '5 min') returning id into v_o2;
  insert into rpc_ids values
    ('org_'||p_label,v_org::text),('biz_'||p_label,v_biz::text),
    ('d1_'||p_label,v_d1::text),('d2_'||p_label,v_d2::text),
    ('dr_'||p_label,v_dr::text),('round_'||p_label,v_round::text),
    ('o1_'||p_label,v_o1::text),('o2_'||p_label,v_o2::text);
end $$;

-- Helper para chamar respond_to_offer e capturar.
-- Helper para chamar claim_delivery e capturar.
-- (uso inline abaixo)

-- ============================================================================
-- respond_to_offer — ACCEPT
-- ============================================================================
select _rpc_setup('accept');
delete from rpc_res;
insert into rpc_res select * from public.respond_to_offer(
  (select v::uuid from rpc_ids where k='o1_accept'),
  (select v::uuid from rpc_ids where k='d1_accept'),
  'accept', null, null, null);
select is((select ok from rpc_res), true, 'R1: accept ok=true');
select is((select reason from rpc_res), 'responded', 'R2: accept reason=responded');
select is(
  (select bid_amount_cents from public.bids where delivery_offer_id=(select v::uuid from rpc_ids where k='o1_accept')),
  1000::bigint,
  'R3: accept bid_amount = driver_offer_cents (1000) — ACEITAR = valor ofertado, não ganhar');

-- ============================================================================
-- respond_to_offer — COUNTER_BID
-- ============================================================================
select _rpc_setup('counter');
delete from rpc_res;
insert into rpc_res select * from public.respond_to_offer(
  (select v::uuid from rpc_ids where k='o1_counter'),
  (select v::uuid from rpc_ids where k='d1_counter'),
  'counter_bid', 1500, null, null);
select is((select ok from rpc_res), true, 'R4: counter_bid ok=true');
select is((select reason from rpc_res), 'responded', 'R5: counter_bid reason=responded');
select is(
  (select bid_amount_cents from public.bids where delivery_offer_id=(select v::uuid from rpc_ids where k='o1_counter')),
  1500::bigint,
  'R6: counter_bid bid_amount = valor informado (1500)');

-- ============================================================================
-- respond_to_offer — DECLINE
-- ============================================================================
select _rpc_setup('decline');
delete from rpc_res;
insert into rpc_res select * from public.respond_to_offer(
  (select v::uuid from rpc_ids where k='o1_decline'),
  (select v::uuid from rpc_ids where k='d1_decline'),
  'decline', null, null, null);
select is((select ok from rpc_res), true, 'R7: decline ok=true');
select is((select reason from rpc_res), 'responded', 'R8: decline reason=responded');
select is(
  (select bid_amount_cents from public.bids where delivery_offer_id=(select v::uuid from rpc_ids where k='o1_decline')),
  null::bigint,
  'R9: decline bid_amount NULL (sem lance econômico)');

-- ============================================================================
-- respond_to_offer — idempotent_replay (mesma key em offer/driver diferentes)
-- ============================================================================
select _rpc_setup('idem');
delete from rpc_res;
insert into rpc_res select * from public.respond_to_offer(
  (select v::uuid from rpc_ids where k='o1_idem'),
  (select v::uuid from rpc_ids where k='d1_idem'),
  'accept', null, 'KEY-IDEM', null);
delete from rpc_res;
insert into rpc_res select * from public.respond_to_offer(
  (select v::uuid from rpc_ids where k='o2_idem'),
  (select v::uuid from rpc_ids where k='d2_idem'),
  'accept', null, 'KEY-IDEM', null);
select is((select ok from rpc_res), true, 'R10: replay com mesma idempotency_key ok=true');
select is((select reason from rpc_res), 'idempotent_replay', 'R11: replay reason=idempotent_replay');

-- ============================================================================
-- respond_to_offer — already_responded (segunda resposta à mesma offer)
-- ============================================================================
select _rpc_setup('already');
delete from rpc_res;
insert into rpc_res select * from public.respond_to_offer(
  (select v::uuid from rpc_ids where k='o1_already'),
  (select v::uuid from rpc_ids where k='d1_already'),
  'accept', null, 'KEY-A', null);
delete from rpc_res;
insert into rpc_res select * from public.respond_to_offer(
  (select v::uuid from rpc_ids where k='o1_already'),
  (select v::uuid from rpc_ids where k='d1_already'),
  'decline', null, 'KEY-B', null);
select is((select ok from rpc_res), true, 'R12: segunda resposta ok=true (terminal)');
select is((select reason from rpc_res), 'already_responded', 'R13: segunda resposta reason=already_responded');

-- ============================================================================
-- respond_to_offer — driver incorreto
-- ============================================================================
select _rpc_setup('wrong');
delete from rpc_res;
insert into rpc_res select * from public.respond_to_offer(
  (select v::uuid from rpc_ids where k='o1_wrong'),
  (select v::uuid from rpc_ids where k='d2_wrong'),  -- driver2 na offer do driver1
  'accept', null, null, null);
select is((select ok from rpc_res), false, 'R14: driver incorreto ok=false');
select is((select reason from rpc_res), 'offer_not_found_for_driver', 'R15: reason=offer_not_found_for_driver');

-- ============================================================================
-- respond_to_offer — round fechada
-- ============================================================================
select _rpc_setup('rc');
update public.dispatch_rounds set status='closed' where id=(select v::uuid from rpc_ids where k='round_rc');
delete from rpc_res;
insert into rpc_res select * from public.respond_to_offer(
  (select v::uuid from rpc_ids where k='o1_rc'),
  (select v::uuid from rpc_ids where k='d1_rc'),
  'accept', null, null, null);
select is((select ok from rpc_res), false, 'R16: round fechada ok=false');
select is((select reason from rpc_res), 'round_not_open', 'R17: reason=round_not_open');

-- ============================================================================
-- respond_to_offer — offer expirada
-- ============================================================================
select _rpc_setup('exp');
update public.delivery_offers set expires_at=now()-interval '1 minute'
  where id=(select v::uuid from rpc_ids where k='o1_exp');
delete from rpc_res;
insert into rpc_res select * from public.respond_to_offer(
  (select v::uuid from rpc_ids where k='o1_exp'),
  (select v::uuid from rpc_ids where k='d1_exp'),
  'accept', null, null, null);
select is((select ok from rpc_res), false, 'R18: offer expirada ok=false');
select is((select reason from rpc_res), 'offer_expired', 'R19: reason=offer_expired');

-- ============================================================================
-- respond_to_offer — delivery não está em searching_driver
-- ============================================================================
select _rpc_setup('dns','assigned');
delete from rpc_res;
insert into rpc_res select * from public.respond_to_offer(
  (select v::uuid from rpc_ids where k='o1_dns'),
  (select v::uuid from rpc_ids where k='d1_dns'),
  'accept', null, null, null);
select is((select ok from rpc_res), false, 'R20: delivery não searching ok=false');
select is((select reason from rpc_res), 'delivery_not_searching', 'R21: reason=delivery_not_searching');

-- ============================================================================
-- claim_delivery — normal
-- ============================================================================
select _rpc_setup('claim');
delete from rpc_res;
insert into rpc_res select * from public.respond_to_offer(
  (select v::uuid from rpc_ids where k='o1_claim'),
  (select v::uuid from rpc_ids where k='d1_claim'),
  'accept', null, null, null);
delete from claim_res;
insert into claim_res select * from public.claim_delivery(
  (select v::uuid from rpc_ids where k='dr_claim'),
  (select v::uuid from rpc_ids where k='d1_claim'),
  (select v::uuid from rpc_ids where k='round_claim'),
  (select v::uuid from rpc_ids where k='o1_claim'), null, null);
select is((select won from claim_res), true, 'C1: claim normal won=true');
select is(
  (select status::text from public.delivery_requests where id=(select v::uuid from rpc_ids where k='dr_claim')),
  'assigned', 'C2: delivery passou a assigned');
select is(
  (select count(*) from public.delivery_assignments
    where delivery_request_id=(select v::uuid from rpc_ids where k='dr_claim') and status='active'),
  1::bigint, 'C3: exatamente uma assignment ativa');

-- ============================================================================
-- claim_delivery — already_assigned (via assignment ativa manual, delivery ainda searching)
-- ============================================================================
select _rpc_setup('aa');
insert into public.delivery_assignments(delivery_request_id, driver_id, status)
  select v::uuid, (select v::uuid from rpc_ids where k='d1_aa'), 'active'
  from rpc_ids where k='dr_aa';
delete from rpc_res;
insert into rpc_res select * from public.respond_to_offer(
  (select v::uuid from rpc_ids where k='o2_aa'),
  (select v::uuid from rpc_ids where k='d2_aa'),
  'accept', null, null, null);
delete from claim_res;
insert into claim_res select * from public.claim_delivery(
  (select v::uuid from rpc_ids where k='dr_aa'),
  (select v::uuid from rpc_ids where k='d2_aa'),
  (select v::uuid from rpc_ids where k='round_aa'),
  (select v::uuid from rpc_ids where k='o2_aa'), null, null);
select is((select won from claim_res), false, 'C4: claim com assignment ativa existente won=false');
select is((select reason from claim_res), 'already_assigned', 'C5: reason=already_assigned (partial unique index)');

-- ============================================================================
-- claim_delivery — delivery não está em searching_driver
-- ============================================================================
select _rpc_setup('ns','draft');
delete from rpc_res;
insert into rpc_res select * from public.respond_to_offer(
  (select v::uuid from rpc_ids where k='o1_ns'),
  (select v::uuid from rpc_ids where k='d1_ns'),
  'accept', null, null, null);
delete from claim_res;
insert into claim_res select * from public.claim_delivery(
  (select v::uuid from rpc_ids where k='dr_ns'),
  (select v::uuid from rpc_ids where k='d1_ns'),
  (select v::uuid from rpc_ids where k='round_ns'),
  (select v::uuid from rpc_ids where k='o1_ns'), null, null);
select is((select won from claim_res), false, 'C6: claim em delivery draft won=false');
select is((select reason from claim_res), 'not_searching_driver', 'C7: reason=not_searching_driver');

-- ============================================================================
-- claim_delivery — offer não pertence à round informada
-- ============================================================================
select _rpc_setup('onf');
delete from rpc_res;
insert into rpc_res select * from public.respond_to_offer(
  (select v::uuid from rpc_ids where k='o1_onf'),
  (select v::uuid from rpc_ids where k='d1_onf'),
  'accept', null, null, null);
delete from claim_res;
insert into claim_res select * from public.claim_delivery(
  (select v::uuid from rpc_ids where k='dr_onf'),
  (select v::uuid from rpc_ids where k='d1_onf'),
  gen_random_uuid(),  -- round inexistente
  (select v::uuid from rpc_ids where k='o1_onf'), null, null);
select is((select won from claim_res), false, 'C8: claim com round inválido won=false');
select is((select reason from claim_res), 'offer_not_found', 'C9: reason=offer_not_found');

-- ============================================================================
-- R16: claim em rodada 2 marca offers da rodada 1 como lost e fecha rodada 1
-- ============================================================================
select _rpc_setup('r16');
do $$
declare v_r2 uuid; v_o2b uuid; v_dr uuid; v_d2 uuid;
begin
  select v::uuid into v_dr from rpc_ids where k='dr_r16';
  select v::uuid into v_d2 from rpc_ids where k='d2_r16';
  insert into public.dispatch_rounds(delivery_request_id,round_number,search_radius_m,max_candidates,driver_offer_cents,expires_at)
    values(v_dr,2,2000,5,1000,now()+interval '5 min') returning id into v_r2;
  insert into public.delivery_offers(delivery_request_id,dispatch_round_id,driver_id,driver_offer_cents,expires_at)
    values(v_dr,v_r2,v_d2,1000,now()+interval '5 min') returning id into v_o2b;
  insert into rpc_ids values('round2_r16',v_r2::text),('o2b_r16',v_o2b::text);
end $$;
delete from rpc_res;
insert into rpc_res select * from public.respond_to_offer(
  (select v::uuid from rpc_ids where k='o2b_r16'),
  (select v::uuid from rpc_ids where k='d2_r16'),
  'accept', null, null, null);
delete from claim_res;
insert into claim_res select * from public.claim_delivery(
  (select v::uuid from rpc_ids where k='dr_r16'),
  (select v::uuid from rpc_ids where k='d2_r16'),
  (select v::uuid from rpc_ids where k='round2_r16'),
  (select v::uuid from rpc_ids where k='o2b_r16'), null, null);
select is((select won from claim_res), true, 'R16a: claim na rodada 2 won=true');
select is(
  (select status::text from public.delivery_offers where id=(select v::uuid from rpc_ids where k='o1_r16')),
  'lost', 'R16b: offer pendente da rodada 1 marcada lost (não apenas a rodada vencedora)');
select is(
  (select status::text from public.dispatch_rounds where id=(select v::uuid from rpc_ids where k='round_r16')),
  'closed', 'R16c: rodada 1 fechada após claim em rodada 2');

-- ============================================================================
-- transition_delivery — cadeia válida completa
-- ============================================================================
select _rpc_setup('trans','draft');
delete from trans_res;
insert into trans_res select * from public.transition_delivery((select v::uuid from rpc_ids where k='dr_trans'),'quoted');
select is((select ok from trans_res), true, 'TR1: draft->quoted ok');
delete from trans_res;
insert into trans_res select * from public.transition_delivery((select v::uuid from rpc_ids where k='dr_trans'),'searching_driver');
select is((select ok from trans_res), true, 'TR2: quoted->searching_driver ok');
delete from trans_res;
insert into trans_res select * from public.transition_delivery((select v::uuid from rpc_ids where k='dr_trans'),'assigned');
select is((select ok from trans_res), true, 'TR3: searching->assigned ok');
delete from trans_res;
insert into trans_res select * from public.transition_delivery((select v::uuid from rpc_ids where k='dr_trans'),'driver_to_pickup');
select is((select ok from trans_res), true, 'TR4: assigned->driver_to_pickup ok');
delete from trans_res;
insert into trans_res select * from public.transition_delivery((select v::uuid from rpc_ids where k='dr_trans'),'at_pickup');
select is((select ok from trans_res), true, 'TR5: driver_to_pickup->at_pickup ok');
delete from trans_res;
insert into trans_res select * from public.transition_delivery((select v::uuid from rpc_ids where k='dr_trans'),'picked_up');
select is((select ok from trans_res), true, 'TR6: at_pickup->picked_up ok');
delete from trans_res;
insert into trans_res select * from public.transition_delivery((select v::uuid from rpc_ids where k='dr_trans'),'in_transit');
select is((select ok from trans_res), true, 'TR7: picked_up->in_transit ok');
-- Sessão 11 (ADR-016 D5): in_transit->delivered agora exige POD pod_type='delivery'.
-- Teste roda como owner; insere POD direto para satisfazer o gate.
insert into public.proof_of_delivery(delivery_request_id, pod_type, storage_path, receiver_name)
  values((select v::uuid from rpc_ids where k='dr_trans'), 'delivery', 'pod/trans.jpg', 'Receiver');
delete from trans_res;
insert into trans_res select * from public.transition_delivery((select v::uuid from rpc_ids where k='dr_trans'),'delivered');
select is((select ok from trans_res), true, 'TR8: in_transit->delivered ok');
select is(
  (select status::text from public.delivery_requests where id=(select v::uuid from rpc_ids where k='dr_trans')),
  'delivered', 'TR9: estado final delivered');
select is(
  (select count(*) from public.delivery_events where delivery_request_id=(select v::uuid from rpc_ids where k='dr_trans')),
  8::bigint, 'TR10: cada transição produziu um delivery_event (8 eventos)');

-- ============================================================================
-- transition_delivery — transições inválidas
-- ============================================================================
select _rpc_setup('inv1','draft');
delete from trans_res;
insert into trans_res select * from public.transition_delivery((select v::uuid from rpc_ids where k='dr_inv1'),'delivered');
select is((select ok from trans_res), false, 'INV1: draft->delivered rejeitado');
select _rpc_setup('inv2','quoted');
delete from trans_res;
insert into trans_res select * from public.transition_delivery((select v::uuid from rpc_ids where k='dr_inv2'),'picked_up');
select is((select ok from trans_res), false, 'INV2: quoted->picked_up rejeitado');
select _rpc_setup('inv3','delivered');
delete from trans_res;
insert into trans_res select * from public.transition_delivery((select v::uuid from rpc_ids where k='dr_inv3'),'in_transit');
select is((select ok from trans_res), false, 'INV3: delivered->in_transit rejeitado');

-- ============================================================================
-- set_driver_availability
-- ============================================================================
select _rpc_setup('avail');
select public.set_driver_availability(
  (select v::uuid from rpc_ids where k='d1_avail'), 'busy', 'test');
select is(
  (select current_availability_status::text from public.drivers where id=(select v::uuid from rpc_ids where k='d1_avail')),
  'busy', 'SA1: current_availability_status atualizado');
select is(
  (select count(*) from public.driver_availability
    where driver_id=(select v::uuid from rpc_ids where k='d1_avail') and status='busy'),
  1::bigint, 'SA2: log append-only recebeu uma entrada');

select * from finish();