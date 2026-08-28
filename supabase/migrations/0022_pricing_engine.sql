-- 0022_pricing_engine.sql
-- Sessão 07 (ADR-012): pricing engine determinístico. Cota a delivery_request em draft:
-- calcula componentes + faixa min/max, snapshot em delivery_quotes, e dispara draft->quoted
-- via transition_delivery (atomicamente). create_quote é SYSTEM-ONLY (primeiro RPC
-- system-only): auth.uid() not null -> not_authorized. Insumos de pricing (distância/
-- duração) vêm do backend (provider de rota na Sessão 20), nunca do business.
-- Nenhuma tabela nova; altera pricing_rules (+multipliers) e delivery_quotes (+min/max).

set search_path = public, pg_catalog;

-- ============================================================================
-- pricing_rules: faixa configurável (piso+teto) via multipliers.
-- min_multiplier/max_multiplier aplicados ao preço-alvo (customer_price/driver_offer)
-- para derivar min/max. Default 1.0 -> faixa degenerada (min=max=alvo).
-- ============================================================================
alter table public.pricing_rules
  add column if not exists min_multiplier numeric(5,4) not null default 1.0
    check (min_multiplier > 0),
  add column if not exists max_multiplier numeric(5,4) not null default 1.0
    check (max_multiplier > 0),
  add constraint pricing_rules_mult_order_chk check (min_multiplier <= max_multiplier);

-- ============================================================================
-- delivery_quotes: faixa min/max (snapshot). Piso+teto de customer_price e driver_offer.
-- ============================================================================
alter table public.delivery_quotes
  add column if not exists min_customer_price_cents bigint not null default 0
    check (min_customer_price_cents >= 0),
  add column if not exists max_customer_price_cents bigint not null default 0
    check (max_customer_price_cents >= 0),
  add column if not exists min_driver_offer_cents bigint not null default 0
    check (min_driver_offer_cents >= 0),
  add column if not exists max_driver_offer_cents bigint not null default 0
    check (max_driver_offer_cents >= 0),
  add constraint delivery_quotes_customer_range_chk
    check (min_customer_price_cents <= max_customer_price_cents),
  add constraint delivery_quotes_driver_range_chk
    check (min_driver_offer_cents <= max_driver_offer_cents);

-- ============================================================================
-- create_quote(p_delivery_request_id, p_distance_meters, p_duration_seconds,
--              p_correlation_id)
-- SECURITY DEFINER, system-only. Cota determinística:
--   1. valida (status='draft', inputs>0)
--   2. seleciona regra (org -> global fallback)
--   3. computa componentes (D2) + faixa (D3)
--   4. transition_delivery('quoted') FIRST (atomico, emite quote_created, seta quoted_at)
--   5. se ok -> insert delivery_quotes (snapshot, status='pending', expires_at=+900s)
--   5b. se not ok -> retorna sem insertar (sem quote órfã)
-- ============================================================================
create or replace function public.create_quote(
  p_delivery_request_id  uuid,
  p_distance_meters      integer,
  p_duration_seconds     integer,
  p_correlation_id       uuid default gen_random_uuid()
) returns table(ok boolean, reason text, quote_id uuid)
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_caller        uuid := auth.uid();
  v_dr            public.delivery_requests%rowtype;
  v_rule          public.pricing_rules%rowtype;
  v_has_rule      boolean := false;
  v_base          bigint;
  v_distance_comp bigint;
  v_vehicle_comp  bigint := 0;
  v_urgency_comp  bigint;
  v_dynamic_comp  bigint := 0;
  v_subtotal_raw  bigint;
  v_subtotal      bigint;
  v_platform_fee  bigint;
  v_customer      bigint;
  v_driver        bigint;
  v_min_customer  bigint;
  v_max_customer  bigint;
  v_min_driver    bigint;
  v_max_driver    bigint;
  v_quote_id      uuid := gen_random_uuid();
  v_ok            boolean;
  v_reason        text;
begin
  -- ---- Authz (D1): system-only ----
  if v_caller is not null then
    return query select false, 'not_authorized', null::uuid; return;
  end if;

  -- ---- Validações de input ----
  if p_distance_meters is null or p_distance_meters <= 0 then
    return query select false, 'invalid_distance', null::uuid; return;
  end if;
  if p_duration_seconds is null or p_duration_seconds <= 0 then
    return query select false, 'invalid_duration', null::uuid; return;
  end if;

  select * into v_dr from public.delivery_requests where id = p_delivery_request_id;
  if not found then
    return query select false, 'delivery_not_found', null::uuid; return;
  end if;
  if v_dr.status <> 'draft' then
    return query select false, 'wrong_state', null::uuid; return;
  end if;
  if v_dr.vehicle_required is null then
    return query select false, 'invalid_vehicle', null::uuid; return;
  end if;

  -- ---- Seleção de regra (D4): org-specific -> global fallback ----
  select * into v_rule from public.pricing_rules
   where organization_id = v_dr.organization_id
     and vehicle_type = v_dr.vehicle_required
     and is_active and effective_from <= now()
   order by effective_from desc
   limit 1;
  v_has_rule := found;
  if not v_has_rule then
    select * into v_rule from public.pricing_rules
     where organization_id is null
       and vehicle_type = v_dr.vehicle_required
       and is_active and effective_from <= now()
     order by effective_from desc
     limit 1;
    v_has_rule := found;
  end if;
  if not v_has_rule then
    return query select false, 'no_pricing_rule', null::uuid; return;
  end if;

  -- ---- Cálculo (D2) ----
  v_base          := v_rule.base_cents;
  -- ceil inteiro: (per_km_cents * meters + 999) / 1000  (sem float no dinheiro)
  v_distance_comp := (v_rule.per_km_cents * p_distance_meters + 999) / 1000;
  v_urgency_comp  := case when v_dr.priority = 'urgent' then v_rule.urgency_add_cents else 0 end;
  v_subtotal_raw  := v_base + v_distance_comp + v_vehicle_comp + v_urgency_comp + v_dynamic_comp;
  v_subtotal      := greatest(v_subtotal_raw, v_rule.min_price_cents);
  v_platform_fee  := v_rule.platform_fee_cents;
  v_customer      := v_subtotal + v_platform_fee;
  v_driver        := v_subtotal - v_platform_fee;
  if v_driver < 0 then
    return query select false, 'pricing_error', null::uuid; return;
  end if;

  -- ---- Faixa (D3) via multipliers (numeric, floor/ceil -> bigint) ----
  v_min_customer := greatest(v_rule.min_price_cents,
                             floor(v_customer::numeric * v_rule.min_multiplier)::bigint);
  v_max_customer := ceil(v_customer::numeric * v_rule.max_multiplier)::bigint;
  v_min_driver   := floor(v_driver::numeric * v_rule.min_multiplier)::bigint;
  if v_min_driver < 0 then v_min_driver := 0; end if;
  v_max_driver   := ceil(v_driver::numeric * v_rule.max_multiplier)::bigint;

  -- ---- Atomicidade (D5): transition FIRST ----
  select t.ok, t.reason into v_ok, v_reason from public.transition_delivery(
    p_delivery_request_id,
    'quoted'::public.delivery_status,
    'system',
    null,
    jsonb_build_object(
      'quote_id', v_quote_id,
      'customer_price_cents', v_customer,
      'driver_offer_cents', v_driver,
      'min_customer_price_cents', v_min_customer,
      'max_customer_price_cents', v_max_customer,
      'pricing_rule_id', v_rule.id),
    p_correlation_id) as t;
  if not v_ok then
    return query select false, v_reason, null::uuid; return;
  end if;

  -- ---- Insert delivery_quotes (snapshot; status='pending'; TTL 900s) ----
  insert into public.delivery_quotes(
    id, delivery_request_id, pricing_rule_id, currency,
    base_cents, distance_component_cents, vehicle_component_cents,
    urgency_component_cents, dynamic_component_cents, subtotal_cents,
    platform_fee_cents, driver_offer_cents, customer_price_cents,
    min_customer_price_cents, max_customer_price_cents,
    min_driver_offer_cents, max_driver_offer_cents,
    distance_meters, duration_seconds, status, expires_at)
  values (
    v_quote_id, p_delivery_request_id, v_rule.id, v_rule.currency,
    v_base, v_distance_comp, v_vehicle_comp, v_urgency_comp, v_dynamic_comp, v_subtotal,
    v_platform_fee, v_driver, v_customer,
    v_min_customer, v_max_customer, v_min_driver, v_max_driver,
    p_distance_meters, p_duration_seconds, 'pending'::public.quote_status,
    now() + interval '900 seconds');

  return query select true, 'quoted', v_quote_id;
end;
$$;

comment on function public.create_quote(uuid, integer, integer, uuid) is
  'Cota determinística (draft->quoted). SECURITY DEFINER, SYSTEM-ONLY (ADR-012 D1). Snapshot em delivery_quotes + faixa min/max. Sem preço de IA; insumos de rota do backend (provider na Sessão 20).';

-- ============================================================================
-- Grants: system-only. revoke PUBLIC; EXECUTE só a service_role (authenticated NÃO
-- recebe — defesa em profundidade antes da checagem de auth.uid). anon: nada.
-- ============================================================================
revoke all on function public.create_quote(uuid, integer, integer, uuid) from public;
grant execute on function public.create_quote(uuid, integer, integer, uuid) to service_role;