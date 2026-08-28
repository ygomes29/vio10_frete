-- 0026_state_machine_pod_rpcs.sql
-- Sessão 11 (ADR-016) — máquina de estados pós-assigned + POD gate.
--
-- 1. transition_delivery (refinada, assinatura inalterada): matriz ator×transição (D1),
--    limite de reatribuição via metadata (D2), cancelled_reason/failed_reason (D3),
--    POD gate em delivered (D5), draft->cancelled em M.
-- 2. submit_proof_of_delivery (nova, driver-scoped): valida + insere POD + emite
--    pod_submitted. NÃO transita (D4/D6/D7).
-- 3. confirm_delivery (nova, system-only): valida POD delivery + transita delivered (D4/D5).
--
-- Nenhuma tabela/coluna nova. Sem novos grants de DML a authenticated (INSERT em POD só
-- via DEFINER). Padrão de assinatura: lat/lng double precision (geography montado
-- server-side) — não expor geography na assinatura (igual 0021).

set search_path = public, extensions, pg_catalog;

-- =========================================================================
-- transition_delivery (refinada — ADR-016 D1/D2/D3/D5)
-- Máquina de estados central. Matriz estrutural M + matriz de papel R[role].
-- Authz: system / admin / driver (assignment ativa) / business (membro org).
-- Actor derivado de auth.uid(). Limite de reatribuição via p_metadata->>'max_reassignments'.
-- POD gate: in_transit->delivered exige POD pod_type='delivery'.
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
security definer
set search_path = public, pg_catalog
as $$
declare
  v_caller  uuid := auth.uid();
  v_from    delivery_status;
  v_struct_ok boolean;
  v_role_ok boolean;
  v_event_type delivery_event_type;
  v_actor_type text := p_actor_type;
  v_actor_id   uuid   := p_actor_id;
  v_my_driver  uuid;
  v_is_admin   boolean;
  v_role       text;
  v_max_reas   int;
  v_reason     text;
begin
  -- ==== Resolução do ator (classe de papel) ====
  if v_caller is not null then
    v_is_admin := exists (select 1 from public.user_platform_roles r
      where r.user_id = v_caller and r.role in ('super_admin','admin','operator'));
    if v_is_admin then
      v_role := 'admin';
      v_actor_type := coalesce(nullif(p_actor_type,''), 'admin');
      v_actor_id   := v_caller;
    else
      select d.id into v_my_driver from public.drivers d where d.user_id = v_caller;
      if v_my_driver is not null and exists (
        select 1 from public.delivery_assignments a
        where a.delivery_request_id = p_delivery_request_id
          and a.driver_id = v_my_driver and a.status = 'active'
      ) then
        v_role := 'driver';
        v_actor_type := 'driver';
        v_actor_id   := v_caller;
      elsif exists (
        select 1 from public.delivery_requests dr
        join public.organization_memberships m on m.organization_id = dr.organization_id
        where dr.id = p_delivery_request_id and m.user_id = v_caller
      ) then
        v_role := 'business';
        v_actor_type := 'business';
        v_actor_id   := v_caller;
      else
        return query select false, 'not_authorized'; return;
      end if;
    end if;
  else
    v_role := 'system';
    v_actor_type := coalesce(nullif(p_actor_type,''), 'system');
    v_actor_id   := p_actor_id;
  end if;

  -- Lock + estado de origem
  select status into v_from from public.delivery_requests
  where id = p_delivery_request_id for update;
  if not found then
    return query select false, 'not_found'; return;
  end if;

  -- ==== Matriz estrutural M (from -> to) ====
  v_struct_ok := (v_from, p_to_status) in (
    ('draft','quoted'),
    ('draft','cancelled'),
    ('quoted','searching_driver'),
    ('quoted','cancelled'),
    ('searching_driver','assigned'),
    ('searching_driver','cancelled'),
    ('searching_driver','expired'),
    ('searching_driver','failed'),
    ('assigned','driver_to_pickup'),
    ('assigned','searching_driver'),
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
  if not v_struct_ok then
    return query select false, 'invalid_transition'; return;
  end if;

  -- ==== Matriz de papel R[role] ====
  if v_role = 'driver' then
    v_role_ok := (v_from, p_to_status) in (
      ('assigned','driver_to_pickup'),
      ('driver_to_pickup','at_pickup'),
      ('at_pickup','picked_up'),
      ('picked_up','in_transit')
    );
  elsif v_role = 'business' then
    v_role_ok := (v_from, p_to_status) in (
      ('draft','cancelled'),
      ('quoted','cancelled'),
      ('quoted','searching_driver'),
      ('searching_driver','cancelled')
    );
  elsif v_role = 'admin' then
    -- tudo de M exceto o conjunto system-only
    v_role_ok := (v_from, p_to_status) in (
      ('draft','cancelled'),
      ('quoted','searching_driver'),
      ('quoted','cancelled'),
      ('searching_driver','cancelled'),
      ('searching_driver','failed'),
      ('assigned','driver_to_pickup'),
      ('assigned','searching_driver'),
      ('assigned','failed'),
      ('assigned','cancelled'),
      ('driver_to_pickup','at_pickup'),
      ('driver_to_pickup','searching_driver'),
      ('at_pickup','picked_up'),
      ('at_pickup','searching_driver'),
      ('at_pickup','failed'),
      ('picked_up','in_transit'),
      ('in_transit','failed'),
      ('in_transit','searching_driver')
    );
  else
    v_role_ok := true;  -- system: tudo de M (já validado)
  end if;
  if not v_role_ok then
    return query select false, 'not_authorized'; return;
  end if;

  -- ==== Limite de reatribuição (D2) ====
  if v_from in ('assigned','driver_to_pickup','in_transit','at_pickup')
     and p_to_status = 'searching_driver' then
    begin
      v_max_reas := nullif(p_metadata->>'max_reassignments','')::int;
    exception when others then v_max_reas := null; end;
    if v_max_reas is not null
       and (select reassignment_count from public.delivery_requests
            where id = p_delivery_request_id) >= v_max_reas then
      return query select false, 'reassignment_limit_reached'; return;
    end if;
    -- supersede assignment ativa + incrementa contador
    update public.delivery_assignments
      set status = 'superseded', ended_at = now(), ended_reason = 'reassigned', updated_at = now()
      where delivery_request_id = p_delivery_request_id and status = 'active';
    update public.delivery_requests set reassignment_count = reassignment_count + 1
      where id = p_delivery_request_id;
  end if;

  -- ==== POD gate (D5): delivered exige POD delivery ====
  if p_to_status = 'delivered' then
    if not exists (
      select 1 from public.proof_of_delivery
      where delivery_request_id = p_delivery_request_id and pod_type = 'delivery'
    ) then
      return query select false, 'pod_required'; return;
    end if;
  end if;

  -- ==== Motivo (D3) ====
  v_reason := p_metadata->>'reason';

  -- ==== Tipo de evento ====
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

  -- ==== Estado + timestamps + reasons ====
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
    expired_at          = case when p_to_status='expired' then now() else expired_at end,
    cancelled_reason    = case when p_to_status='cancelled' then coalesce(v_reason, cancelled_reason) else cancelled_reason end,
    failed_reason       = case when p_to_status='failed' then coalesce(v_reason, failed_reason) else failed_reason end
  where id = p_delivery_request_id;

  insert into public.delivery_events
    (delivery_request_id, event_type, actor_type, actor_id, from_status, to_status, metadata, correlation_id)
  values (p_delivery_request_id, v_event_type, v_actor_type, v_actor_id, v_from, p_to_status,
    coalesce(p_metadata, '{}'::jsonb), p_correlation_id);

  return query select true, 'transitioned';
end;
$$;

comment on function public.transition_delivery(uuid,delivery_status,text,uuid,jsonb,uuid) is
  'Máquina de estados central (SECURITY DEFINER, ADR-016). Matriz estrutural M + matriz de papel R[system|admin|driver|business]. Limite de reatribuição via metadata->>max_reassignments. POD gate em delivered. Actor derivado de auth.uid().';

-- =========================================================================
-- submit_proof_of_delivery (nova — ADR-016 D4/D6/D7)
-- Driver-scoped (driver com assignment ativa) ou system. Valida completude, insere POD,
-- emite pod_submitted. NÃO transita (delivered é via confirm_delivery, system-only).
-- lat/lng double precision -> geography montado server-side (padrão 0021).
-- =========================================================================
create or replace function public.submit_proof_of_delivery(
  p_delivery_request_id uuid,
  p_pod_type            pod_type,
  p_storage_path        text default null,
  p_otp_code            text default null,
  p_receiver_name       text default null,
  p_location_lat        double precision default null,
  p_location_lng        double precision default null,
  p_notes               text default null,
  p_correlation_id      uuid default gen_random_uuid()
) returns table(ok boolean, reason text, pod_id uuid)
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $$
declare
  v_caller   uuid := auth.uid();
  v_my_driver uuid;
  v_actor_type text := 'system';
  v_actor_id   uuid := null;
  v_status   delivery_status;
  v_pod_id   uuid;
  v_loc      geography(Point,4326);
begin
  -- Authz: system (auth.uid null) OU driver com assignment ativa.
  if v_caller is not null then
    select d.id into v_my_driver from public.drivers d where d.user_id = v_caller;
    if v_my_driver is null or not exists (
      select 1 from public.delivery_assignments a
      where a.delivery_request_id = p_delivery_request_id
        and a.driver_id = v_my_driver and a.status = 'active'
    ) then
      return query select false, 'not_authorized', null::uuid; return;
    end if;
    v_actor_type := 'driver';
    v_actor_id   := v_caller;
  end if;

  -- Delivery existe + estado correto.
  select status into v_status from public.delivery_requests
  where id = p_delivery_request_id for update;
  if not found then
    return query select false, 'delivery_not_found', null::uuid; return;
  end if;

  if p_pod_type = 'delivery'::pod_type then
    if v_status <> 'in_transit' then
      return query select false, 'wrong_state', null::uuid; return;
    end if;
  else  -- pickup
    if v_status not in ('driver_to_pickup','at_pickup','picked_up','in_transit') then
      return query select false, 'wrong_state', null::uuid; return;
    end if;
  end if;

  -- Completude (D6).
  if p_pod_type = 'delivery'::pod_type then
    if (p_storage_path is null and p_otp_code is null) or p_receiver_name is null then
      return query select false, 'invalid_pod', null::uuid; return;
    end if;
  else  -- pickup
    if p_storage_path is null and p_otp_code is null and p_notes is null then
      return query select false, 'invalid_pod', null::uuid; return;
    end if;
  end if;

  -- Geography (se lat E lng presentes).
  if p_location_lat is not null and p_location_lng is not null then
    v_loc := st_setsrid(st_makepoint(p_location_lng, p_location_lat), 4326)::geography(Point,4326);
  end if;

  -- Insere POD (unique violation -> pod_already_submitted).
  begin
    insert into public.proof_of_delivery
      (delivery_request_id, pod_type, storage_path, otp_code, receiver_name,
       location_point, notes, captured_at)
    values (p_delivery_request_id, p_pod_type, p_storage_path, p_otp_code, p_receiver_name,
       v_loc, p_notes, now())
    returning id into v_pod_id;
  exception when unique_violation then
    return query select false, 'pod_already_submitted', null::uuid; return;
  end;

  -- Auditoria.
  insert into public.delivery_events
    (delivery_request_id, event_type, actor_type, actor_id, to_status, metadata, correlation_id)
  values (p_delivery_request_id, 'pod_submitted'::delivery_event_type, v_actor_type, v_actor_id,
    v_status,
    jsonb_build_object('pod_id', v_pod_id, 'pod_type', p_pod_type::text),
    p_correlation_id);

  return query select true, 'submitted', v_pod_id;
end;
$$;

comment on function public.submit_proof_of_delivery(uuid,pod_type,text,text,text,double precision,double precision,text,uuid) is
  'Submete proof of delivery (driver-scoped ou system, ADR-016). Valida completude, insere POD, emite pod_submitted. NÃO transita (delivered via confirm_delivery).';

-- =========================================================================
-- confirm_delivery (nova — ADR-016 D4/D5/D7, system-only)
-- Valida POD delivery existe e transita in_transit -> delivered via transition_delivery
-- (que re-valida o POD gate). Submeter POD != entregue.
-- =========================================================================
create or replace function public.confirm_delivery(
  p_delivery_request_id uuid,
  p_correlation_id      uuid default gen_random_uuid()
) returns table(ok boolean, reason text, pod_id uuid)
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_caller uuid := auth.uid();
  v_pod_id uuid;
  v_ok     boolean;
  v_reason text;
begin
  -- System-only (defense in depth; grant só a service_role).
  if v_caller is not null then
    return query select false, 'not_authorized', null::uuid; return;
  end if;

  -- POD delivery existe?
  select id into v_pod_id from public.proof_of_delivery
  where delivery_request_id = p_delivery_request_id and pod_type = 'delivery'
  limit 1;
  if not found then
    return query select false, 'pod_required', null::uuid; return;
  end if;

  -- Transita in_transit -> delivered (transition_delivery re-valida POD gate + matriz system).
  select t.ok, t.reason into v_ok, v_reason
  from public.transition_delivery(
    p_delivery_request_id,
    'delivered'::public.delivery_status,
    'system', null,
    jsonb_build_object('pod_id', v_pod_id),
    p_correlation_id) as t;

  if v_ok then
    return query select true, 'delivered', v_pod_id;
  else
    return query select false, v_reason, null::uuid;
  end if;
end;
$$;

comment on function public.confirm_delivery(uuid,uuid) is
  'Confirma entrega (system-only, ADR-016). Valida POD delivery e transita in_transit->delivered. Submeter POD != entregue.';

-- =========================================================================
-- Grants
-- =========================================================================
revoke all on function public.transition_delivery(uuid,delivery_status,text,uuid,jsonb,uuid) from public;
revoke all on function public.submit_proof_of_delivery(uuid,pod_type,text,text,text,double precision,double precision,text,uuid) from public;
revoke all on function public.confirm_delivery(uuid,uuid) from public;

-- transition_delivery: service_role + authenticated (inalterado: driver/business/admin chamam direto).
grant execute on function public.transition_delivery(uuid,delivery_status,text,uuid,jsonb,uuid) to service_role, authenticated;
-- submit_proof_of_delivery: driver-scoped -> service_role + authenticated.
grant execute on function public.submit_proof_of_delivery(uuid,pod_type,text,text,text,double precision,double precision,text,uuid) to service_role, authenticated;
-- confirm_delivery: system-only -> só service_role (authenticated sem EXECUTE, defesa em profundidade).
grant execute on function public.confirm_delivery(uuid,uuid) to service_role;