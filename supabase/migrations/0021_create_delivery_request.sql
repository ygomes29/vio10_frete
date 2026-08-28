-- 0021_create_delivery_request.sql
-- Sessão 06 (ADR-011): criação da corrida. RPC SECURITY DEFINER (Modelo B) que insere
-- delivery_requests (status='draft') + delivery_items + delivery_events(delivery_created)
-- numa transação. Sem preço (pricing = Sessão 07, draft -> quoted). Snapshots auto-contidos;
-- pontos geography montados server-side via PostGIS. external_reference = dedup de criação.

set search_path = public, extensions, pg_catalog;

create or replace function public.create_delivery_request(
  p_organization_id        uuid,
  p_business_id            uuid,
  p_business_location_id   uuid,
  p_pickup_address         text,
  p_pickup_lat             double precision,
  p_pickup_lng             double precision,
  p_pickup_contact_name    text,
  p_pickup_contact_phone   text,
  p_delivery_address       text,
  p_delivery_lat           double precision,
  p_delivery_lng           double precision,
  p_delivery_contact_name  text,
  p_delivery_contact_phone text,
  p_vehicle_required       public.vehicle_type,
  p_priority               public.delivery_priority,
  p_scheduled_at           timestamptz,
  p_origin                 public.delivery_request_origin,
  p_external_reference     text,
  p_notes                  text,
  p_instructions           text,
  p_items                  jsonb,
  p_correlation_id         uuid
) returns table(ok boolean, reason text, delivery_request_id uuid)
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $$
declare
  v_caller       uuid := auth.uid();
  v_actor_type   text;
  v_actor_id     uuid;
  v_id           uuid;
  v_pickup_pt    geography(Point,4326);
  v_delivery_pt  geography(Point,4326);
  v_item         jsonb;
  v_desc         text;
  v_qty          int;
  v_item_count   int := 0;
  v_priority     public.delivery_priority := coalesce(p_priority, 'standard');
  v_origin       public.delivery_request_origin := coalesce(p_origin, 'dashboard');
begin
  -- ---- Authz: system (null) | is_platform_admin | membro da org ----
  if v_caller is not null then
    if not public.is_platform_admin()
       and not exists (
         select 1 from public.organization_memberships m
         where m.user_id = v_caller and m.organization_id = p_organization_id
       ) then
      return query select false, 'not_authorized', null::uuid; return;
    end if;
  end if;

  -- ---- Ator (D6) ----
  if v_caller is null then
    v_actor_type := 'system'; v_actor_id := null;
  elsif public.is_platform_admin() then
    v_actor_type := 'admin'; v_actor_id := v_caller;
  else
    v_actor_type := 'business'; v_actor_id := v_caller;
  end if;

  -- ---- Validações de tenancy ----
  if not exists (select 1 from public.organizations where id = p_organization_id) then
    return query select false, 'org_not_found', null::uuid; return;
  end if;
  if not exists (
    select 1 from public.businesses b
    where b.id = p_business_id and b.organization_id = p_organization_id
  ) then
    return query select false, 'business_not_in_org', null::uuid; return;
  end if;
  if p_business_location_id is not null
     and not exists (
       select 1 from public.business_locations bl
       where bl.id = p_business_location_id and bl.business_id = p_business_id
     ) then
    return query select false, 'location_not_in_business', null::uuid; return;
  end if;

  -- ---- Validações de campos obrigatórios ----
  if p_pickup_address is null or p_pickup_address = ''
     or p_pickup_lat is null or p_pickup_lng is null
     or p_pickup_contact_phone is null or p_pickup_contact_phone = ''
  then
    return query select false, 'invalid_pickup', null::uuid; return;
  end if;
  if p_delivery_address is null or p_delivery_address = ''
     or p_delivery_lat is null or p_delivery_lng is null
     or p_delivery_contact_phone is null or p_delivery_contact_phone = ''
  then
    return query select false, 'invalid_delivery', null::uuid; return;
  end if;
  if p_vehicle_required is null then
    return query select false, 'invalid_vehicle', null::uuid; return;
  end if;

  -- ---- Itens: pré-valida ANTES de inserir (não deixa request sem itens) ----
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    return query select false, 'invalid_items', null::uuid; return;
  end if;
  for v_item in select * from jsonb_array_elements(p_items) loop
    v_desc := v_item ->> 'description';
    v_qty  := nullif(v_item ->> 'quantity', '')::int;
    if v_desc is null or v_desc = '' or v_qty is null or v_qty <= 0 then
      return query select false, 'invalid_items', null::uuid; return;
    end if;
    v_item_count := v_item_count + 1;
  end loop;

  -- ---- Pontos (PostGIS, server-side) ----
  v_pickup_pt   := st_setsrid(st_makepoint(p_pickup_lng,   p_pickup_lat),   4326)::geography(Point,4326);
  v_delivery_pt := st_setsrid(st_makepoint(p_delivery_lng, p_delivery_lat), 4326)::geography(Point,4326);

  -- ---- Insert delivery_request (status='draft'); external_reference dedup ----
  insert into public.delivery_requests(
    organization_id, business_id, business_location_id,
    pickup_address, pickup_latitude, pickup_longitude, pickup_point,
    pickup_contact_name, pickup_contact_phone,
    delivery_address, delivery_latitude, delivery_longitude, delivery_point,
    delivery_contact_name, delivery_contact_phone,
    vehicle_required, priority, scheduled_at, origin, external_reference,
    notes, instructions, status)
  values (
    p_organization_id, p_business_id, p_business_location_id,
    p_pickup_address, p_pickup_lat, p_pickup_lng, v_pickup_pt,
    p_pickup_contact_name, p_pickup_contact_phone,
    p_delivery_address, p_delivery_lat, p_delivery_lng, v_delivery_pt,
    p_delivery_contact_name, p_delivery_contact_phone,
    p_vehicle_required, v_priority, p_scheduled_at, v_origin, p_external_reference,
    p_notes, p_instructions, 'draft')
  on conflict (organization_id, external_reference) do nothing
  returning id into v_id;

  if v_id is null then
    -- external_reference já existe para esta org -> idempotente (dedup, NÃO retry)
    select id into v_id from public.delivery_requests
    where organization_id = p_organization_id and external_reference = p_external_reference;
    return query select true, 'already_exists', v_id; return;
  end if;

  -- ---- Insert delivery_items ----
  for v_item in select * from jsonb_array_elements(p_items) loop
    insert into public.delivery_items(
      delivery_request_id, description, quantity, weight_g,
      length_cm, width_cm, height_cm, notes)
    values (
      v_id,
      v_item ->> 'description',
      nullif(v_item ->> 'quantity', '')::int,
      nullif(v_item ->> 'weight_g', '')::int,
      nullif(v_item ->> 'length_cm', '')::int,
      nullif(v_item ->> 'width_cm', '')::int,
      nullif(v_item ->> 'height_cm', '')::int,
      v_item ->> 'notes');
  end loop;

  -- ---- Evento de auditoria (delivery_created) ----
  insert into public.delivery_events(
    delivery_request_id, event_type, actor_type, actor_id,
    from_status, to_status, metadata, correlation_id)
  values (
    v_id, 'delivery_created'::public.delivery_event_type, v_actor_type, v_actor_id,
    null, 'draft'::public.delivery_status,
    jsonb_build_object('origin', v_origin::text, 'external_reference', p_external_reference,
                       'items_count', v_item_count),
    coalesce(p_correlation_id, gen_random_uuid()));

  return query select true, 'created', v_id;
end;
$$;

comment on function public.create_delivery_request(
  uuid,uuid,uuid, text,double precision,double precision,text,text,
  text,double precision,double precision,text,text,
  public.vehicle_type,public.delivery_priority,timestamptz,public.delivery_request_origin,
  text,text,text,jsonb,uuid) is
  'Cria corrida (draft) + itens + evento delivery_created. SECURITY DEFINER, ADR-011. Sem preço. external_reference = dedup.';

-- ============================================================================
-- Grants (least-privilege, Modelo B). revoke PUBLIC; EXECUTE em service_role +
-- authenticated (user-facing: dashboard business/admin/operator + system path).
-- Nenhum DML a authenticated. anon: nada.
-- ============================================================================
revoke all on function public.create_delivery_request(
  uuid,uuid,uuid, text,double precision,double precision,text,text,
  text,double precision,double precision,text,text,
  public.vehicle_type,public.delivery_priority,timestamptz,public.delivery_request_origin,
  text,text,text,jsonb,uuid)
from public;

grant execute on function public.create_delivery_request(
  uuid,uuid,uuid, text,double precision,double precision,text,text,
  text,double precision,double precision,text,text,
  public.vehicle_type,public.delivery_priority,timestamptz,public.delivery_request_origin,
  text,text,text,jsonb,uuid)
to service_role, authenticated;