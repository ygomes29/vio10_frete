-- 0028_pod_completo_rpcs.sql
-- Sessão 12 (ADR-017) — RPCs de POD completo. Referenciam o enum 'otp_generated' (add em
-- 0027, transação separada — gotcha ALTER TYPE ADD VALUE in-tx, ADR-016 D9 / ADR-017 D8).
--
-- RPCs:
--   1. generate_delivery_otp        (NOVA, system-only — 5º system-only) — gera OTP do recebedor.
--   2. submit_proof_of_delivery      (REFINADA, assinatura inalterada) — valida OTP contra delivery_otps.
--   3. confirm_delivery             (REFINADA, +p_geo_tolerance_m) — drop da antiga (uuid,uuid) + nova (uuid,int,uuid).
--   4. transition_delivery          (REFINADA, assinatura inalterada) — gate de pickup POD (D3) + gate de geo (D2).
-- Assinatura de transition_delivery INALTERADA (callers internos preservados: create_quote /
-- confirm_quote / confirm_delivery). Nenhuma tabela/coluna nova (delivery_otps + enum em 0027).

-- =========================================================================
-- 1. generate_delivery_otp — system-only (5º system-only).
--    Gera código de 6 dígitos (crypto via gen_random_bytes), armazena hash salt+sha256,
--    TTL + max_attempts, retorna o plaintext APENAS ao caller system (backend envia via
--    WhatsApp ao delivery_contact_phone — camada externa, ADR-017 D6). Upsert no unique
--    (delivery_request_id): regenerar reseta attempts/consumed_at/expires_at (D1).
-- =========================================================================
create or replace function public.generate_delivery_otp(
  p_delivery_request_id uuid,
  p_ttl_seconds    int default 900,
  p_max_attempts   int default 5,
  p_correlation_id uuid default gen_random_uuid()
) returns table(ok boolean, reason text, otp_code text)
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $$
declare
  v_caller uuid := auth.uid();
  v_status delivery_status;
  v_code   text;
  v_salt   text;
  v_hash   text;
  v_bytes  bytea;
  v_raw    bigint;
begin
  -- System-only (auth.uid not null -> not_authorized).
  if v_caller is not null then
    return query select false, 'not_authorized', null::text; return;
  end if;

  -- Delivery existe + estado onde o OTP faz sentido (ainda não terminal).
  select status into v_status from public.delivery_requests
  where id = p_delivery_request_id for update;
  if not found then
    return query select false, 'not_found', null::text; return;
  end if;
  if v_status not in ('assigned','driver_to_pickup','at_pickup','picked_up','in_transit') then
    return query select false, 'wrong_state', null::text; return;
  end if;

  -- Código de 6 dígitos crypto-secure (gen_random_bytes).
  v_bytes := gen_random_bytes(4);
  v_raw := (get_byte(v_bytes, 0)::bigint << 24)
         + (get_byte(v_bytes, 1)::bigint << 16)
         + (get_byte(v_bytes, 2)::bigint << 8)
         +  get_byte(v_bytes, 3)::bigint;
  v_code := lpad((v_raw % 1000000)::text, 6, '0');

  -- Salt por linha + hash sha256 (pgcrypto). Derrota rainbow tables no vazamento do DB.
  v_salt := encode(gen_random_bytes(8), 'hex');
  v_hash := encode(digest(v_code::bytea || v_salt::bytea, 'sha256'), 'hex');

  -- Upsert no unique (delivery_request_id): (re)gera e reseta tentativas/consumo.
  insert into public.delivery_otps
    (delivery_request_id, code_hash, salt, expires_at, attempts, max_attempts, consumed_at, generated_at)
  values (p_delivery_request_id, v_hash, v_salt,
          now() + (p_ttl_seconds * interval '1 second'),
          0, p_max_attempts, null, now())
  on conflict (delivery_request_id) do update
    set code_hash    = excluded.code_hash,
        salt         = excluded.salt,
        expires_at   = excluded.expires_at,
        attempts     = 0,
        max_attempts = excluded.max_attempts,
        consumed_at  = null,
        generated_at = now();

  -- Auditoria: otp_generated (actor system).
  insert into public.delivery_events
    (delivery_request_id, event_type, actor_type, actor_id, to_status, metadata, correlation_id)
  values (p_delivery_request_id, 'otp_generated'::delivery_event_type, 'system', null, v_status,
    jsonb_build_object('ttl_seconds', p_ttl_seconds, 'max_attempts', p_max_attempts),
    p_correlation_id);

  return query select true, 'generated', v_code;
end;
$$;

-- =========================================================================
-- 2. submit_proof_of_delivery — REFINADA (assinatura inalterada).
--    Adiciona validação de OTP contra delivery_otps quando pod_type='delivery' e
--    p_otp_code is not null (D1/D4). Foto-only (otp_code null) pula validação OTP.
--    Match -> consumed_at=now() na MESMA tx do insert do POD (atomicidade).
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
  -- OTP (D1/D4):
  v_otp        record;
  v_otp_hash   text;
  v_otp_consumed boolean := false;
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

  -- ==== Validação de OTP (D1/D4, Sessão 12) ====
  -- Delivery POD com otp_code deve bater com OTP gerado (select for update, lock de linha).
  -- Foto-only (otp_code null) pula — either-or preservado (back-compat Sessão 11).
  if p_pod_type = 'delivery'::pod_type and p_otp_code is not null then
    select o.code_hash, o.salt, o.expires_at, o.attempts, o.max_attempts, o.consumed_at
      into v_otp
    from public.delivery_otps o
    where o.delivery_request_id = p_delivery_request_id
    for update;

    if not found then
      return query select false, 'otp_not_generated', null::uuid; return;
    end if;
    if v_otp.consumed_at is not null then
      return query select false, 'otp_already_used', null::uuid; return;
    end if;
    if now() > v_otp.expires_at then
      return query select false, 'otp_expired', null::uuid; return;
    end if;
    if v_otp.attempts >= v_otp.max_attempts then
      return query select false, 'otp_max_attempts', null::uuid; return;
    end if;

    v_otp_hash := encode(digest(p_otp_code::bytea || v_otp.salt::bytea, 'sha256'), 'hex');
    if v_otp_hash <> v_otp.code_hash then
      -- Código incorreto: incrementa tentativas; locka se atingiu max.
      update public.delivery_otps
        set attempts = attempts + 1
        where delivery_request_id = p_delivery_request_id;
      if v_otp.attempts + 1 >= v_otp.max_attempts then
        return query select false, 'otp_max_attempts', null::uuid; return;
      end if;
      return query select false, 'otp_invalid', null::uuid; return;
    end if;

    -- Match: consome o OTP na mesma transação do insert do POD (atomicidade).
    update public.delivery_otps
      set consumed_at = now()
      where delivery_request_id = p_delivery_request_id;
    v_otp_consumed := true;
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
    jsonb_build_object('pod_id', v_pod_id, 'pod_type', p_pod_type::text,
                       'otp_consumed', v_otp_consumed),
    p_correlation_id);

  return query select true, 'submitted', v_pod_id;
end;
$$;

-- =========================================================================
-- 3. confirm_delivery — REFINADA (+p_geo_tolerance_m, D2).
--    Assinatura muda (uuid,uuid) -> (uuid,int,uuid): drop da antiga antes de criar a nova
--    (senão create or replace cria overload órfão). System-only inalterado. Valida POD
--    delivery existe, chama transition_delivery('delivered') repassando geo_tolerance_m.
-- =========================================================================
drop function if exists public.confirm_delivery(uuid, uuid);

create or replace function public.confirm_delivery(
  p_delivery_request_id uuid,
  p_geo_tolerance_m     int default null,
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
  v_meta   jsonb;
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

  -- Metadata: pod_id sempre; geo_tolerance_m só se informado (default 200m no gate).
  v_meta := jsonb_build_object('pod_id', v_pod_id);
  if p_geo_tolerance_m is not null then
    v_meta := v_meta || jsonb_build_object('geo_tolerance_m', p_geo_tolerance_m);
  end if;

  -- Transita in_transit -> delivered (transition_delivery re-valida POD gate + geo gate).
  select t.ok, t.reason into v_ok, v_reason
  from public.transition_delivery(
    p_delivery_request_id,
    'delivered'::public.delivery_status,
    'system', null, v_meta, p_correlation_id) as t;

  if v_ok then
    return query select true, 'delivered', v_pod_id;
  else
    return query select false, v_reason, null::uuid;
  end if;
end;
$$;

-- =========================================================================
-- 4. transition_delivery — REFINADA (assinatura inalterada, D2 + D3).
--    Adiciona:
--      D3 — gate de pickup POD em at_pickup->picked_up (pickup_pod_required).
--      D2 — gate de geo em in_transit->delivered (pod_geolocation_out_of_range),
--           tolerância configurável via metadata.geo_tolerance_m (default 200m),
--           SKIP quando o POD não tem location (GPS indisponível; MVP aceita).
--    search_path ganha 'extensions' (PostGIS st_distance/geography). Matriz ator×transição,
--    limite de reatribuição, reasons, timestamps, eventos — inalterados.
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
set search_path = public, extensions, pg_catalog
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
  -- Geo gate (D2):
  v_pod_loc geography(Point,4326);
  v_dest    geography(Point,4326);
  v_tol     int;
  v_dist    double precision;
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

  -- ==== POD gate delivery (D5/Sessão 11): delivered exige POD delivery ====
  if p_to_status = 'delivered' then
    if not exists (
      select 1 from public.proof_of_delivery
      where delivery_request_id = p_delivery_request_id and pod_type = 'delivery'
    ) then
      return query select false, 'pod_required'; return;
    end if;
  end if;

  -- ==== Pickup POD gate (D3/Sessão 12): picked_up exige POD pickup ====
  if p_to_status = 'picked_up' then
    if not exists (
      select 1 from public.proof_of_delivery
      where delivery_request_id = p_delivery_request_id and pod_type = 'pickup'
    ) then
      return query select false, 'pickup_pod_required'; return;
    end if;
  end if;

  -- ==== Geo gate (D2/Sessão 12): delivered exige POD location dentro da tolerância ====
  -- Tolerância configurável via metadata.geo_tolerance_m (default 200m). SKIP se o POD
  -- delivery não capturou localização (GPS indisponível; MVP aceita — não se pode validar
  -- o que não foi capturado). Duro quando há localização e excede.
  if p_to_status = 'delivered' then
    begin
      v_tol := nullif(p_metadata->>'geo_tolerance_m','')::int;
    exception when others then v_tol := null; end;
    if v_tol is null then v_tol := 200; end if;

    v_pod_loc := null;
    select location_point into v_pod_loc
    from public.proof_of_delivery
    where delivery_request_id = p_delivery_request_id and pod_type = 'delivery'
    limit 1;

    if v_pod_loc is not null then
      select delivery_point into v_dest
      from public.delivery_requests where id = p_delivery_request_id;
      v_dist := st_distance(v_pod_loc, v_dest);
      if v_dist > v_tol then
        return query select false, 'pod_geolocation_out_of_range'; return;
      end if;
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

-- =========================================================================
-- Grants (D9). revoke public + least-privilege.
-- =========================================================================
revoke all on function public.generate_delivery_otp(uuid,int,int,uuid) from public;
revoke all on function public.submit_proof_of_delivery(uuid,pod_type,text,text,text,double precision,double precision,text,uuid) from public;
revoke all on function public.confirm_delivery(uuid,int,uuid) from public;
revoke all on function public.transition_delivery(uuid,delivery_status,text,uuid,jsonb,uuid) from public;

-- generate_delivery_otp: system-only — execute só a service_role (5º system-only).
grant execute on function public.generate_delivery_otp(uuid,int,int,uuid) to service_role;
-- submit_proof_of_delivery: driver/system — service_role + authenticated (com check auth.uid).
grant execute on function public.submit_proof_of_delivery(uuid,pod_type,text,text,text,double precision,double precision,text,uuid) to service_role, authenticated;
-- confirm_delivery: system-only — execute só a service_role.
grant execute on function public.confirm_delivery(uuid,int,uuid) to service_role;
-- transition_delivery: system/admin/driver/business — service_role + authenticated (com check auth.uid).
grant execute on function public.transition_delivery(uuid,delivery_status,text,uuid,jsonb,uuid) to service_role, authenticated;

comment on function public.generate_delivery_otp(uuid,int,int,uuid) is
  'ViO10: gera OTP do recebedor (Sessão 12 / 0028, ADR-017 D1/D9). System-only (5º). Hash salt+sha256, TTL, max_attempts. Retorna plaintext só ao caller system (backend envia via WhatsApp). Upsert regenera.';
comment on function public.submit_proof_of_delivery(uuid,pod_type,text,text,text,double precision,double precision,text,uuid) is
  'ViO10: submete POD (Sessão 12 refinada, ADR-016 D6 + ADR-017 D1/D4). Driver/system. Valida OTP contra delivery_otps (delivery+otp_code). Match consume na mesma tx do insert. Não transita.';
comment on function public.confirm_delivery(uuid,int,uuid) is
  'ViO10: confirma entrega (Sessão 12 refinada, ADR-016 + ADR-017 D2). System-only. Valida POD delivery existe, chama transition_delivery(delivered) repassando geo_tolerance_m.';
comment on function public.transition_delivery(uuid,delivery_status,text,uuid,jsonb,uuid) is
  'ViO10: máquina de estados central (Sessão 12 refinada, ADR-016 + ADR-017 D2/D3). Gates: POD delivery (delivered), pickup POD (picked_up), geo (delivered, tolerância configurável, skip sem location). Matriz ator×transição.';