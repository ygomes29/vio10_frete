-- 0024_bid_engine.sql
-- Sessão 09 (ADR-014): bid engine. Um movimento:
--   select_winner_and_claim (system-only DEFINER, terceiro system-only apos create_quote/
--   open_dispatch_round): fecha a rodada, coleta candidatos validos (offers respondidas
--   accepted/counter_bid + re-valida eligibility do driver no close), pontua deterministicamente
--   (normalizacao min-max de bid_amount_cents + ST_Distance, pesos de param, tie-break
--   deterministico), escolhe o vencedor, chama claim_delivery internamente (atomico). Sem
--   vencedor -> fecha a rodada manualmente + expira offers pending + round_closed + retorna
--   no_candidates (orquestrador abre a proxima rodada de raio maior). Com vencedor ->
--   winner_selected (scores no metadata, auditoria) + claim_delivery (atribui, fecha a
--   rodada, R16 perde as demais offers, driver_assigned).
-- Nenhuma tabela/coluna nova — tudo ja existe em 0005/0009/0010/0016. O vencedor vive em
-- delivery_assignments (active) + delivery_offers.status='won' + delivery_events; sem
-- winner_* em dispatch_rounds. ACEITAR != GANHAR (ADR-006). Idempotencia por estado.

-- ============================================================================
-- select_winner_and_claim(p_dispatch_round_id, p_weight_price, p_weight_distance,
--   p_max_location_age_seconds, p_correlation_id)
-- SECURITY DEFINER, system-only (terceiro system-only). Pontua/ordena candidatos validos
-- e chama claim_delivery. Ate aqui a selecao nao existia (BACKEND.md §4 previa).
-- ============================================================================
create or replace function public.select_winner_and_claim(
  p_dispatch_round_id         uuid,
  p_weight_price              numeric default 1.0,
  p_weight_distance           numeric default 1.0,
  p_max_location_age_seconds  integer default 300,
  p_correlation_id            uuid default gen_random_uuid()
) returns table(ok boolean, reason text, winner_driver_id uuid, winner_offer_id uuid, winner_bid_id uuid)
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $$
declare
  v_caller           uuid := auth.uid();
  v_round            public.dispatch_rounds%rowtype;
  v_dr               public.delivery_requests%rowtype;
  v_delivery_id      uuid;
  v_cand             record;
  v_winner_driver    uuid;
  v_winner_offer     uuid;
  v_winner_bid       uuid;
  v_scores           jsonb := '[]'::jsonb;
  v_cand_count       integer := 0;
  v_won              boolean;
  v_claim_reason     text;
  v_round_closed     boolean := false;
begin
  -- ---- Authz (D1): system-only ----
  if v_caller is not null then
    return query select false, 'not_authorized', null::uuid, null::uuid, null::uuid;
    return;
  end if;

  -- ---- Validações de input (D2.1) ----
  if p_weight_price is null or p_weight_price < 0
     or p_weight_distance is null or p_weight_distance < 0
     or (p_weight_price = 0 and p_weight_distance = 0)
     or p_max_location_age_seconds is null or p_max_location_age_seconds <= 0
  then
    return query select false, 'invalid_param', null::uuid, null::uuid, null::uuid;
    return;
  end if;

  -- ---- Lock + valida rodada (D2.1) ----
  select * into v_round from public.dispatch_rounds
   where id = p_dispatch_round_id for update;
  if not found then
    return query select false, 'not_found', null::uuid, null::uuid, null::uuid;
    return;
  end if;
  if v_round.status <> 'open' then
    return query select false, 'round_not_open', null::uuid, null::uuid, null::uuid;
    return;
  end if;
  v_delivery_id := v_round.delivery_request_id;

  -- ---- Lock + valida delivery searching_driver (D2.2) ----
  select * into v_dr from public.delivery_requests
   where id = v_delivery_id for update;
  if not found then
    return query select false, 'delivery_not_found', null::uuid, null::uuid, null::uuid;
    return;
  end if;
  if v_dr.status <> 'searching_driver' then
    return query select false, 'wrong_state', null::uuid, null::uuid, null::uuid;
    return;
  end if;

  -- ---- Coleta + pontua candidatos validos (D3/D4) ----
  -- Offers respondidas (accepted/counter_bid) com driver ainda elegivel no close +
  -- offer nao expirada. Normalizacao min-max por window; score = Σ weight*(1-norm).
  -- Tie-break deterministico: score desc, dist_m asc, responded_at asc, driver_id asc.
  for v_cand in
    with candidates as (
      select o.id as offer_id, o.driver_id, o.driver_offer_cents, o.expires_at,
             o.responded_at,
             b.id as bid_id, b.bid_amount_cents,
             st_distance(dl.position, v_dr.pickup_point) as dist_m
        from public.delivery_offers o
        join public.bids b on b.delivery_offer_id = o.id and b.driver_id = o.driver_id
        join public.drivers d on d.id = o.driver_id
        join public.vehicles v on v.id = d.current_vehicle_id
        join public.driver_locations dl on dl.driver_id = d.id
       where o.dispatch_round_id = p_dispatch_round_id
         and o.status in ('accepted','counter_bid')
         and o.expires_at > now()
         and d.account_status = 'active'
         and d.current_availability_status = 'available'
         and v.vehicle_type = v_dr.vehicle_required
         and not exists (
           select 1 from public.delivery_assignments a
            where a.driver_id = d.id and a.status = 'active')
         and dl.position is not null
         and dl.captured_at > now() - (p_max_location_age_seconds || ' seconds')::interval
         and st_dwithin(dl.position, v_dr.pickup_point, v_round.search_radius_m)
    ),
    scored as (
      select c.*,
             ((c.bid_amount_cents - min(c.bid_amount_cents) over ())::numeric
               / nullif((max(c.bid_amount_cents) over () - min(c.bid_amount_cents) over ()), 0)) as norm_bid,
             ((c.dist_m - min(c.dist_m) over ())::numeric
               / nullif((max(c.dist_m) over () - min(c.dist_m) over ()), 0)) as norm_dist
        from candidates c
    )
    select s.offer_id, s.driver_id, s.bid_id, s.bid_amount_cents, s.dist_m, s.responded_at,
           (p_weight_price * (1 - coalesce(s.norm_bid, 0))
            + p_weight_distance * (1 - coalesce(s.norm_dist, 0))) as score
      from scored s
     order by score desc, dist_m asc, responded_at asc, driver_id asc
  loop
    v_cand_count := v_cand_count + 1;
    v_scores := v_scores || jsonb_build_array(jsonb_build_object(
      'driver_id', v_cand.driver_id, 'offer_id', v_cand.offer_id,
      'bid_id', v_cand.bid_id, 'bid_amount_cents', v_cand.bid_amount_cents,
      'dist_m', v_cand.dist_m, 'score', v_cand.score));
    if v_winner_offer is null then
      v_winner_offer  := v_cand.offer_id;
      v_winner_driver  := v_cand.driver_id;
      v_winner_bid     := v_cand.bid_id;
    end if;
  end loop;

  -- ---- 0 candidatos: fecha a rodada manualmente (D2.4) ----
  if v_winner_offer is null then
    update public.dispatch_rounds
       set status = 'closed'::public.dispatch_round_status,
           closed_at = now(), updated_at = now()
     where id = p_dispatch_round_id;
    -- offers pending (nao respondidas) expiram
    update public.delivery_offers
       set status = 'expired'::public.delivery_offer_status, updated_at = now()
     where dispatch_round_id = p_dispatch_round_id and status = 'pending';
    insert into public.delivery_events(
      delivery_request_id, event_type, actor_type, actor_id,
      from_status, to_status, metadata, correlation_id)
    values (
      v_delivery_id, 'round_closed'::public.delivery_event_type,
      'system', null,
      'searching_driver'::public.delivery_status, 'searching_driver'::public.delivery_status,
      jsonb_build_object('round_id', p_dispatch_round_id, 'round_number', v_round.round_number,
                         'reason', 'no_candidates', 'candidate_count', 0),
      p_correlation_id);
    return query select true, 'no_candidates', null::uuid, null::uuid, null::uuid;
    return;
  end if;

  -- ---- ≥1 candidato: emite winner_selected (D6, scores no metadata) e claim ----
  insert into public.delivery_events(
    delivery_request_id, event_type, actor_type, actor_id,
    from_status, to_status, metadata, correlation_id)
  values (
    v_delivery_id, 'winner_selected'::public.delivery_event_type,
    'system', null,
    'searching_driver'::public.delivery_status, 'searching_driver'::public.delivery_status,
    jsonb_build_object('round_id', p_dispatch_round_id, 'round_number', v_round.round_number,
                       'candidate_count', v_cand_count,
                       'winner_driver_id', v_winner_driver, 'winner_offer_id', v_winner_offer,
                       'winner_bid_id', v_winner_bid, 'candidates', v_scores),
    p_correlation_id);

  -- ---- claim_delivery atomico (D5): valida round open, atribui, fecha rodada, R16 ----
  select t.won, t.reason into v_won, v_claim_reason
    from public.claim_delivery(
      v_delivery_id, v_winner_driver, p_dispatch_round_id, v_winner_offer, v_winner_bid,
      p_correlation_id) as t;

  if v_won then
    return query select true, 'won', v_winner_driver, v_winner_offer, v_winner_bid;
    return;
  end if;

  -- ---- Claim falhou (race de outra rodada): fecha nossa rodada como superseded (D2.5) ----
  if v_claim_reason in ('already_assigned','not_searching_driver','delivery_not_found') then
    update public.dispatch_rounds
       set status = 'closed'::public.dispatch_round_status,
           closed_at = now(), updated_at = now()
     where id = p_dispatch_round_id and status = 'open';
    insert into public.delivery_events(
      delivery_request_id, event_type, actor_type, actor_id,
      from_status, to_status, metadata, correlation_id)
    values (
      v_delivery_id, 'round_closed'::public.delivery_event_type,
      'system', null,
      'searching_driver'::public.delivery_status, 'searching_driver'::public.delivery_status,
      jsonb_build_object('round_id', p_dispatch_round_id, 'round_number', v_round.round_number,
                         'reason', 'superseded_by_concurrent_claim',
                         'claim_reason', v_claim_reason, 'candidate_count', v_cand_count),
      p_correlation_id);
    return query select false, v_claim_reason, null::uuid, null::uuid, null::uuid;
    return;
  end if;

  -- ---- Demais reasons (round_not_open/offer_expired/offer_not_accepted/oferta nao found) ----
  return query select false, v_claim_reason, null::uuid, null::uuid, null::uuid;
end;
$$;

comment on function public.select_winner_and_claim(uuid, numeric, numeric, integer, uuid) is
  'Bid engine (system-only, ADR-014). Pontua candidatos validos (bid_amount+ST_Distance, normalizacao min-max, pesos de param), escolhe vencedor deterministico e chama claim_delivery atomico. Sem vencedor -> fecha rodada + no_candidates. ACEITAR != GANHAR. Sem tabela nova.';

-- ============================================================================
-- Grants (D1/D8): system-only -> service_role SOMENTE (como create_quote/open_dispatch_round).
-- authenticated: sem EXECUTE (defesa em profundidade). anon: nada.
-- ============================================================================
revoke all on function public.select_winner_and_claim(uuid, numeric, numeric, integer, uuid) from public;
grant execute on function public.select_winner_and_claim(uuid, numeric, numeric, integer, uuid) to service_role;