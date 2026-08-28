-- 0023_dispatch_engine.sql
-- Sessão 08 (ADR-013): dispatch engine. Dois movimentos:
--   1. confirm_quote (user-scoped DEFINER): membro da org/operator/admin/system confirma a
--      cotação pendente -> quoted -> searching_driver (transition_delivery), marca a quote
--      'confirmed' + confirmed_at, emite quote_confirmed.
--   2. open_dispatch_round (system-only DEFINER, segundo system-only apos create_quote):
--      orquestrador abre uma rodada de dispatch num raio, busca candidatos por PostGIS
--      (ST_DWithin em driver_locations vs pickup_point) + eligibility (veiculo compativel,
--      available, ativo, sem assignment ativa, localizacao fresca), cria dispatch_round +
--      delivery_offers atomicamente, emite round_opened + offer_created.
-- Nenhuma tabela/coluna nova — tudo ja existe em 0005/0007/0009/0010. Raio progressivo e
-- orquestrado (backend chama open_dispatch_round N vezes); fechar rodada/scoring/claim e
-- Sessao 09-10. Idempotencia por estado (ADR-012 D8).

-- ============================================================================
-- confirm_quote(p_delivery_request_id, p_correlation_id)
-- SECURITY DEFINER, user-scoped (system | is_platform_admin | membro da org da corrida).
-- Transition-first (quoted->searching_driver); se ok, confirma a quote pendente.
-- ============================================================================
create or replace function public.confirm_quote(
  p_delivery_request_id  uuid,
  p_correlation_id       uuid default gen_random_uuid()
) returns table(ok boolean, reason text)
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_caller       uuid := auth.uid();
  v_actor_type   text;
  v_actor_id     uuid;
  v_dr           public.delivery_requests%rowtype;
  v_quote        public.delivery_quotes%rowtype;
  v_ok           boolean;
  v_reason       text;
begin
  -- ---- Authz (D1): system | is_platform_admin | membro da org da corrida ----
  if v_caller is not null then
    if not public.is_platform_admin()
       and not exists (
         select 1 from public.delivery_requests dr
         join public.organization_memberships m on m.organization_id = dr.organization_id
         where dr.id = p_delivery_request_id and m.user_id = v_caller
       ) then
      return query select false, 'not_authorized'; return;
    end if;
  end if;

  -- ---- Ator (D7) ----
  if v_caller is null then
    v_actor_type := 'system'; v_actor_id := null;
  elsif public.is_platform_admin() then
    v_actor_type := 'admin'; v_actor_id := v_caller;
  else
    v_actor_type := 'business'; v_actor_id := v_caller;
  end if;

  -- ---- Valida delivery existe e status='quoted' ----
  select * into v_dr from public.delivery_requests where id = p_delivery_request_id;
  if not found then
    return query select false, 'delivery_not_found'; return;
  end if;
  if v_dr.status <> 'quoted' then
    return query select false, 'wrong_state'; return;
  end if;

  -- ---- Valida quote pendente + nao expirada (a mais recente) ----
  select * into v_quote from public.delivery_quotes
   where delivery_request_id = p_delivery_request_id
     and status = 'pending'
   order by created_at desc
   limit 1
   for update;
  if not found then
    return query select false, 'no_pending_quote'; return;
  end if;
  if v_quote.expires_at is not null and v_quote.expires_at < now() then
    return query select false, 'quote_expired'; return;
  end if;

  -- ---- Atomicidade (D6): transition FIRST (quoted->searching_driver) ----
  select t.ok, t.reason into v_ok, v_reason from public.transition_delivery(
    p_delivery_request_id,
    'searching_driver'::public.delivery_status,
    v_actor_type,
    v_actor_id,
    jsonb_build_object('quote_id', v_quote.id),
    p_correlation_id) as t;
  if not v_ok then
    return query select false, v_reason; return;
  end if;

  -- ---- Confirma a quote (status='confirmed', confirmed_at=now) ----
  update public.delivery_quotes
     set status = 'confirmed'::public.quote_status,
         confirmed_at = now(),
         updated_at = now()
   where id = v_quote.id;

  -- ---- Evento de auditoria (quote_confirmed) ----
  insert into public.delivery_events(
    delivery_request_id, event_type, actor_type, actor_id,
    from_status, to_status, metadata, correlation_id)
  values (
    p_delivery_request_id, 'quote_confirmed'::public.delivery_event_type,
    v_actor_type, v_actor_id,
    'quoted'::public.delivery_status, 'searching_driver'::public.delivery_status,
    jsonb_build_object('quote_id', v_quote.id),
    p_correlation_id);

  return query select true, 'confirmed';
end;
$$;

comment on function public.confirm_quote(uuid, uuid) is
  'Confirma cotação pendente (quoted->searching_driver). SECURITY DEFINER, user-scoped (ADR-013 D1). Marca quote confirmed + confirmed_at. Transition-first (sem quote confirmed órfã). Idempotente por estado.';

-- ============================================================================
-- open_dispatch_round(p_delivery_request_id, p_search_radius_m, p_max_candidates,
--   p_driver_offer_cents, p_response_window_seconds, p_max_location_age_seconds,
--   p_correlation_id)
-- SECURITY DEFINER, system-only (segundo system-only apos create_quote). Abre uma rodada
-- de dispatch: valida searching_driver + params + sem rodada aberta, cria dispatch_round
-- + delivery_offers para cada candidato elegivel (D3), emite round_opened + offer_created.
-- ============================================================================
create or replace function public.open_dispatch_round(
  p_delivery_request_id       uuid,
  p_search_radius_m           integer,
  p_max_candidates            integer,
  p_driver_offer_cents        bigint,
  p_response_window_seconds   integer,
  p_max_location_age_seconds  integer default 300,
  p_correlation_id            uuid default gen_random_uuid()
) returns table(ok boolean, reason text, round_id uuid, candidate_count integer)
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $$
declare
  v_caller        uuid := auth.uid();
  v_dr            public.delivery_requests%rowtype;
  v_round_id      uuid := gen_random_uuid();
  v_round_number  integer;
  v_expires       timestamptz;
  v_open_count    integer;
  v_cand          record;
  v_count         integer := 0;
begin
  -- ---- Authz (D2): system-only ----
  if v_caller is not null then
    return query select false, 'not_authorized', null::uuid, 0; return;
  end if;

  -- ---- Validações de input (D4.1) ----
  if p_search_radius_m is null or p_search_radius_m <= 0
     or p_max_candidates is null or p_max_candidates <= 0
     or p_driver_offer_cents is null or p_driver_offer_cents < 0
     or p_response_window_seconds is null or p_response_window_seconds <= 0
  then
    return query select false, 'invalid_param', null::uuid, 0; return;
  end if;

  -- ---- Valida delivery existe e status='searching_driver' ----
  select * into v_dr from public.delivery_requests where id = p_delivery_request_id;
  if not found then
    return query select false, 'delivery_not_found', null::uuid, 0; return;
  end if;
  if v_dr.status <> 'searching_driver' then
    return query select false, 'wrong_state', null::uuid, 0; return;
  end if;

  -- ---- Guarda de rodada aberta (D4.2) ----
  select count(*) into v_open_count from public.dispatch_rounds
   where delivery_request_id = p_delivery_request_id and status = 'open';
  if v_open_count > 0 then
    return query select false, 'round_already_open', null::uuid, 0; return;
  end if;

  -- ---- round_number monotônico (D4.3) ----
  select coalesce(max(round_number), 0) + 1 into v_round_number
    from public.dispatch_rounds where delivery_request_id = p_delivery_request_id;
  v_expires := now() + (p_response_window_seconds || ' seconds')::interval;

  -- ---- INSERT dispatch_round (D4.4) ----
  insert into public.dispatch_rounds(
    id, delivery_request_id, round_number, status,
    search_radius_m, max_candidates, driver_offer_cents, config_snapshot,
    expires_at)
  values (
    v_round_id, p_delivery_request_id, v_round_number, 'open'::public.dispatch_round_status,
    p_search_radius_m, p_max_candidates, p_driver_offer_cents,
    jsonb_build_object(
      'search_radius_m', p_search_radius_m,
      'max_candidates', p_max_candidates,
      'driver_offer_cents', p_driver_offer_cents,
      'response_window_seconds', p_response_window_seconds,
      'max_location_age_seconds', p_max_location_age_seconds),
    v_expires);

  -- ---- Query candidatos (D3) + INSERT delivery_offers (D4.6) ----
  for v_cand in
    select d.id as driver_id,
           st_distance(dl.position, v_dr.pickup_point) as dist_m
      from public.drivers d
      join public.vehicles v on v.id = d.current_vehicle_id
      join public.driver_locations dl on dl.driver_id = d.id
     where d.account_status = 'active'
       and d.current_availability_status = 'available'
       and v.vehicle_type = v_dr.vehicle_required
       and not exists (
         select 1 from public.delivery_assignments a
          where a.driver_id = d.id and a.status = 'active')
       and dl.position is not null
       and dl.captured_at > now() - (p_max_location_age_seconds || ' seconds')::interval
       and st_dwithin(dl.position, v_dr.pickup_point, p_search_radius_m)
     order by st_distance(dl.position, v_dr.pickup_point) asc
     limit p_max_candidates
  loop
    begin
      insert into public.delivery_offers(
        id, delivery_request_id, dispatch_round_id, driver_id,
        driver_offer_cents, status, expires_at)
      values (
        gen_random_uuid(), p_delivery_request_id, v_round_id, v_cand.driver_id,
        p_driver_offer_cents, 'pending'::public.delivery_offer_status, v_expires);
      v_count := v_count + 1;
    exception when unique_violation then
      -- UK (round, driver): não deveria ocorrer (drivers distintos), mas tolerante.
      null;
    end;
  end loop;

  -- ---- Eventos de auditoria (D4.7): round_opened + offer_created por offer ----
  insert into public.delivery_events(
    delivery_request_id, event_type, actor_type, actor_id,
    from_status, to_status, metadata, correlation_id)
  values (
    p_delivery_request_id, 'round_opened'::public.delivery_event_type,
    'system', null,
    'searching_driver'::public.delivery_status, 'searching_driver'::public.delivery_status,
    jsonb_build_object('round_id', v_round_id, 'round_number', v_round_number,
                       'search_radius_m', p_search_radius_m, 'candidate_count', v_count),
    p_correlation_id);

  if v_count > 0 then
    insert into public.delivery_events(
      delivery_request_id, event_type, actor_type, actor_id,
      from_status, to_status, metadata, correlation_id)
    select
      p_delivery_request_id, 'offer_created'::public.delivery_event_type,
      'system', null,
      'searching_driver'::public.delivery_status, 'searching_driver'::public.delivery_status,
      jsonb_build_object('round_id', v_round_id, 'driver_id', o.driver_id,
                         'offer_id', o.id, 'expires_at', v_expires),
      p_correlation_id
      from public.delivery_offers o
     where o.dispatch_round_id = v_round_id;
  end if;

  -- ---- Retorna (D4.8): cria a rodada mesmo com 0 candidatos (audit) ----
  return query select true, 'opened', v_round_id, v_count;
end;
$$;

comment on function public.open_dispatch_round(uuid, integer, integer, bigint, integer, integer, uuid) is
  'Abre rodada de dispatch (system-only, ADR-013 D2). Busca candidatos por PostGIS + eligibility (D3); cria dispatch_round + delivery_offers atomicamente. Raio progressivo = orquestrador chama N vezes. Sem tabela nova.';

-- ============================================================================
-- Grants (D1/D2/D8).
-- confirm_quote: user-facing -> service_role + authenticated (como create_delivery_request).
-- open_dispatch_round: system-only -> service_role SOMENTE (como create_quote).
-- anon: nada.
-- ============================================================================
revoke all on function public.confirm_quote(uuid, uuid) from public;
grant execute on function public.confirm_quote(uuid, uuid) to service_role, authenticated;

revoke all on function public.open_dispatch_round(uuid, integer, integer, bigint, integer, integer, uuid) from public;
grant execute on function public.open_dispatch_round(uuid, integer, integer, bigint, integer, integer, uuid) to service_role;