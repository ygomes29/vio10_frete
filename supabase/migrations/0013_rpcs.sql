-- 0013_rpcs.sql
-- Funções transacionais fundamentais. ADR-001 / ADR-007.
-- SECURITY INVOKER (não DEFINER) + search_path fixo. Chamadas vêm do backend (service role,
-- que bypassa RLS). SECURITY DEFINER NÃO é usado como atalho para bypassar RLS.

-- =========================================================================
-- claim_delivery: atribuição ATÔMICA. Garantia final do invariante "uma
-- assignment ativa". Protegida por FOR UPDATE na delivery_requests + partial
-- unique index em delivery_assignments. Mesmo concorrência n8n -> um vencedor.
-- =========================================================================
create or replace function public.claim_delivery(
  p_delivery_request_id uuid,
  p_driver_id           uuid,
  p_dispatch_round_id   uuid,
  p_delivery_offer_id   uuid,
  p_bid_id              uuid default null,
  p_correlation_id      uuid default gen_random_uuid()
) returns table(won boolean, reason text)
language plpgsql
set search_path = public, pg_catalog
as $$
declare
  v_status delivery_status;
  v_offer_status delivery_offer_status;
  v_offer_expires timestamptz;
  v_round_status dispatch_round_status;
begin
  -- Trava a linha da corrida (serializa claims concorrentes).
  select dr.status into v_status
  from public.delivery_requests dr
  where dr.id = p_delivery_request_id
  for update;

  if not found then
    return query select false, 'delivery_not_found';
    return;
  end if;

  if v_status <> 'searching_driver' then
    return query select false, 'not_searching_driver';
    return;
  end if;

  -- Valida offer: pertence à round, ao driver informado, e é resposta aceitável.
  select o.status, o.expires_at, r.status
    into v_offer_status, v_offer_expires, v_round_status
  from public.delivery_offers o
  join public.dispatch_rounds r on r.id = o.dispatch_round_id
  where o.id = p_delivery_offer_id
    and o.dispatch_round_id = p_dispatch_round_id
    and o.driver_id = p_driver_id
  for update of o;

  if not found then
    return query select false, 'offer_not_found';
    return;
  end if;

  if v_round_status <> 'open' then
    return query select false, 'round_not_open';
    return;
  end if;

  if v_offer_status not in ('accepted','counter_bid') then
    return query select false, 'offer_not_accepted';
    return;
  end if;

  if v_offer_expires is not null and v_offer_expires < now() then
    return query select false, 'offer_expired';
    return;
  end if;

  -- Tenta criar a assignment ativa. O partial unique index é a garantia física:
  -- se outra concorrente já inseriu, cai em unique_violation -> 'already_assigned'.
  begin
    insert into public.delivery_assignments
      (delivery_request_id, driver_id, dispatch_round_id, delivery_offer_id, bid_id, status)
    values (p_delivery_request_id, p_driver_id, p_dispatch_round_id, p_delivery_offer_id, p_bid_id, 'active');
  exception when unique_violation then
    return query select false, 'already_assigned';
    return;
  end;

  -- Vencedor: atualiza estado, offer, round, event.
  update public.delivery_requests
    set status = 'assigned', assigned_at = now(), updated_at = now()
    where id = p_delivery_request_id;

  update public.delivery_offers set status = 'won', responded_at = now(), updated_at = now()
    where id = p_delivery_offer_id;

  -- R16 (corrigido): TODAS as offers ainda respondíveis da corrida (em qualquer rodada,
  -- não apenas da rodada vencedora) deixam de ser respondíveis. Evita respostas tardias
  -- inconsistentes e race conditions cross-round após a atribuição oficial.
  update public.delivery_offers set status = 'lost', updated_at = now()
    where delivery_request_id = p_delivery_request_id
      and id <> p_delivery_offer_id
      and status in ('accepted','counter_bid','pending');

  -- Fecha TODAS as rodadas abertas da corrida (a vencedora e quaisquer outras abertas).
  update public.dispatch_rounds
    set status = 'closed', closed_at = now(), updated_at = now()
    where delivery_request_id = p_delivery_request_id and status = 'open';

  insert into public.delivery_events
    (delivery_request_id, event_type, actor_type, actor_id, to_status, metadata, correlation_id)
  values (p_delivery_request_id, 'driver_assigned', 'system', p_driver_id,
    'assigned'::delivery_status,
    jsonb_build_object('driver_id', p_driver_id, 'offer_id', p_delivery_offer_id,
                       'round_id', p_dispatch_round_id, 'bid_id', p_bid_id),
    p_correlation_id);

  return query select true, 'won';
end;
$$;

comment on function public.claim_delivery(uuid,uuid,uuid,uuid,uuid,uuid) is
  'Atribuição atômica. Único caminho para virar vencedor oficial. Garantia: FOR UPDATE + partial unique index.';

-- =========================================================================
-- respond_to_offer: registra ACCEPT/COUNTER_BID/DECLINE. IDEMPOTENTE. NÃO atribui.
-- ACEITAR = lance igual a driver_offer_cents (participa da seleção, não ganha).
-- =========================================================================
create or replace function public.respond_to_offer(
  p_delivery_offer_id uuid,
  p_driver_id         uuid,
  p_response_type     bid_response_type,
  p_bid_amount_cents  bigint default null,
  p_idempotency_key   text default null,
  p_correlation_id    uuid default gen_random_uuid()
) returns table(ok boolean, reason text, bid_id uuid)
language plpgsql
set search_path = public, pg_catalog
as $$
declare
  v_offer         public.delivery_offers%rowtype;
  v_round_status  dispatch_round_status;
  v_del_status    delivery_status;
  v_existing      public.bids%rowtype;
  v_amount        bigint;
  v_event_type    delivery_event_type;
  v_new_bid_id    uuid;
begin
  -- Idempotência 1: resposta já existe para (offer, driver) -> terminal, retorna.
  select * into v_existing
  from public.bids
  where delivery_offer_id = p_delivery_offer_id and driver_id = p_driver_id
  for update;

  if found then
    return query select true, 'already_responded', v_existing.id;
    return;
  end if;

  -- Idempotência 2: idempotency_key já usada -> replay, retorna o existente.
  if p_idempotency_key is not null then
    select * into v_existing from public.bids where idempotency_key = p_idempotency_key;
    if found then
      return query select true, 'idempotent_replay', v_existing.id;
      return;
    end if;
  end if;

  -- Offer deve pertencer ao driver informado.
  select * into v_offer from public.delivery_offers
  where id = p_delivery_offer_id and driver_id = p_driver_id
  for update;

  if not found then
    return query select false, 'offer_not_found_for_driver', null::uuid;
    return;
  end if;

  select r.status into v_round_status
  from public.dispatch_rounds r where r.id = v_offer.dispatch_round_id for update;
  select dr.status into v_del_status
  from public.delivery_requests dr where dr.id = v_offer.delivery_request_id for update;

  if v_round_status <> 'open' then
    return query select false, 'round_not_open', null::uuid; return;
  end if;
  if v_offer.status <> 'pending' then
    return query select false, 'offer_already_responded', null::uuid; return;
  end if;
  if v_offer.expires_at < now() then
    return query select false, 'offer_expired', null::uuid; return;
  end if;
  if v_del_status <> 'searching_driver' then
    return query select false, 'delivery_not_searching', null::uuid; return;
  end if;

  case p_response_type
    when 'accept' then
      v_amount := v_offer.driver_offer_cents;
      v_event_type := 'offer_accepted';
    when 'counter_bid' then
      v_amount := p_bid_amount_cents;
      v_event_type := 'counter_bid_received';
      if v_amount is null or v_amount <= 0 then
        return query select false, 'invalid_bid_amount', null::uuid; return;
      end if;
    when 'decline' then
      v_amount := null;
      v_event_type := 'offer_declined';
    else
      return query select false, 'invalid_response_type', null::uuid; return;
  end case;

  insert into public.bids
    (delivery_offer_id, driver_id, delivery_request_id, response_type, bid_amount_cents, idempotency_key, correlation_id)
  values (p_delivery_offer_id, p_driver_id, v_offer.delivery_request_id, p_response_type, v_amount, p_idempotency_key, p_correlation_id)
  returning id into v_new_bid_id;

  update public.delivery_offers set
    status = case p_response_type
               when 'accept' then 'accepted'::delivery_offer_status
               when 'counter_bid' then 'counter_bid'::delivery_offer_status
               when 'decline' then 'declined'::delivery_offer_status
             end,
    responded_at = now(),
    updated_at = now()
  where id = p_delivery_offer_id;

  insert into public.delivery_events
    (delivery_request_id, event_type, actor_type, actor_id, metadata, correlation_id)
  values (v_offer.delivery_request_id, v_event_type, 'driver', p_driver_id,
    jsonb_build_object('offer_id', p_delivery_offer_id, 'bid_amount_cents', v_amount, 'response', p_response_type),
    p_correlation_id);

  return query select true, 'responded', v_new_bid_id;
end;
$$;

comment on function public.respond_to_offer(uuid,uuid,bid_response_type,bigint,text,uuid) is
  'Registra resposta a oferta (idempotente). NÃO atribui. ACEITAR = lance igual ao ofertado.';

-- =========================================================================
-- transition_delivery: máquina de estados central. Ninguém seta status direto.
-- Matriz de transições permitidas. Trata reatribuição (supersede assignment anterior).
-- =========================================================================
create or replace function public.transition_delivery(
  p_delivery_request_id uuid,
  p_to_status          delivery_status,
  p_actor_type         text default 'system',
  p_actor_id           uuid default null,
  p_metadata           jsonb default null,
  p_correlation_id     uuid default gen_random_uuid()
) returns table(ok boolean, reason text)
language plpgsql
set search_path = public, pg_catalog
as $$
declare
  v_from delivery_status;
  v_allowed boolean;
  v_event_type delivery_event_type;
begin
  select status into v_from from public.delivery_requests
  where id = p_delivery_request_id for update;

  if not found then
    return query select false, 'not_found'; return;
  end if;

  v_allowed := (v_from, p_to_status) in (
    ('draft','quoted'),
    ('quoted','searching_driver'),
    ('quoted','cancelled'),
    ('searching_driver','assigned'),       -- via claim_delivery normalmente
    ('searching_driver','cancelled'),
    ('searching_driver','expired'),
    ('searching_driver','failed'),
    ('assigned','driver_to_pickup'),
    ('assigned','searching_driver'),        -- reatribuição
    ('assigned','failed'),
    ('assigned','cancelled'),
    ('driver_to_pickup','at_pickup'),
    ('driver_to_pickup','searching_driver'),
    ('at_pickup','picked_up'),
    ('at_pickup','searching_driver'),
    ('at_pickup','failed'),
    ('picked_up','in_transit'),
    ('in_transit','delivered'),
    ('in_transit','failed'),
    ('in_transit','searching_driver')
  );

  if not v_allowed then
    return query select false, 'invalid_transition'; return;
  end if;

  -- Reatribuição: encerra assignment ativa anterior antes de voltar a searching.
  if v_from in ('assigned','driver_to_pickup','in_transit') and p_to_status = 'searching_driver' then
    update public.delivery_assignments
      set status = 'superseded', ended_at = now(), ended_reason = 'reassigned', updated_at = now()
      where delivery_request_id = p_delivery_request_id and status = 'active';
    update public.delivery_requests set reassignment_count = reassignment_count + 1
      where id = p_delivery_request_id;
  end if;

  -- Mapeia evento.
  v_event_type := case p_to_status
    when 'quoted' then 'quote_created'::delivery_event_type
    when 'searching_driver' then 'dispatch_started'::delivery_event_type
    when 'assigned' then 'driver_assigned'::delivery_event_type
    when 'driver_to_pickup' then 'driver_to_pickup'::delivery_event_type
    when 'at_pickup' then 'arrived_at_pickup'::delivery_event_type
    when 'picked_up' then 'picked_up'::delivery_event_type
    when 'in_transit' then 'in_transit'::delivery_event_type
    when 'delivered' then 'delivered'::delivery_event_type
    when 'cancelled' then 'cancelled'::delivery_event_type
    when 'failed' then 'failed'::delivery_event_type
    when 'expired' then 'expired'::delivery_event_type
    else 'delivery_created'::delivery_event_type
  end;

  update public.delivery_requests set
    status = p_to_status,
    updated_at = now(),
    quoted_at           = case when p_to_status='quoted' then now() else quoted_at end,
    dispatch_started_at = case when p_to_status='searching_driver' and dispatch_started_at is null then now() else dispatch_started_at end,
    assigned_at         = case when p_to_status='assigned' then now() else assigned_at end,
    pickup_arrived_at   = case when p_to_status='at_pickup' then now() else pickup_arrived_at end,
    picked_up_at        = case when p_to_status='picked_up' then now() else picked_up_at end,
    in_transit_at       = case when p_to_status='in_transit' then now() else in_transit_at end,
    delivered_at        = case when p_to_status='delivered' then now() else delivered_at end,
    cancelled_at        = case when p_to_status='cancelled' then now() else cancelled_at end,
    expired_at          = case when p_to_status='expired' then now() else expired_at end
  where id = p_delivery_request_id;

  insert into public.delivery_events
    (delivery_request_id, event_type, actor_type, actor_id, from_status, to_status, metadata, correlation_id)
  values (p_delivery_request_id, v_event_type, p_actor_type, p_actor_id, v_from, p_to_status,
    coalesce(p_metadata, '{}'::jsonb), p_correlation_id);

  return query select true, 'transitioned';
end;
$$;

comment on function public.transition_delivery(uuid,delivery_status,text,uuid,jsonb,uuid) is
  'Máquina de estados central. Matriz de transições. Supersede assignment anterior em reatribuição.';

-- =========================================================================
-- set_driver_availability: atualiza estado atual + log (atômico).
-- =========================================================================
create or replace function public.set_driver_availability(
  p_driver_id  uuid,
  p_status     driver_availability_status,
  p_reason     text default null
) returns void
language plpgsql
set search_path = public, pg_catalog
as $$
begin
  update public.drivers
    set current_availability_status = p_status, updated_at = now()
    where id = p_driver_id;
  insert into public.driver_availability (driver_id, status, reason)
    values (p_driver_id, p_status, p_reason);
end;
$$;

comment on function public.set_driver_availability(uuid,driver_availability_status,text) is
  'Atualiza estado atual (drivers) + append em log (driver_availability) numa transação.';