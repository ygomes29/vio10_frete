-- 0008_pricing.sql
-- Pricing determinístico. pricing_rules = configuração; delivery_quotes = snapshot.
-- ADR-008: valores em BIGINT cents. Currency BRL.

create table if not exists public.pricing_rules (
  id                    uuid primary key default gen_random_uuid(),
  organization_id       uuid references public.organizations(id) on delete cascade,  -- null = regra global da plataforma
  vehicle_type          vehicle_type not null,
  base_cents            bigint not null check (base_cents >= 0),
  per_km_cents          bigint not null check (per_km_cents >= 0),
  per_minute_cents      bigint not null check (per_minute_cents >= 0),
  urgency_add_cents     bigint not null check (urgency_add_cents >= 0),
  min_price_cents       bigint not null check (min_price_cents >= 0),
  platform_fee_cents    bigint not null check (platform_fee_cents >= 0),
  currency              text not null default 'BRL',
  effective_from        timestamptz not null default now(),
  is_active             boolean not null default true,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);
create trigger trg_pricing_rules_updated_at
  before update on public.pricing_rules
  for each row execute function public.set_updated_at();
create index if not exists idx_pricing_rules_org_vehicle
  on public.pricing_rules(organization_id, vehicle_type) where is_active;

-- delivery_quotes: snapshot imutável dos componentes e valores.
create table if not exists public.delivery_quotes (
  id                          uuid primary key default gen_random_uuid(),
  delivery_request_id         uuid not null references public.delivery_requests(id) on delete restrict,
  pricing_rule_id             uuid references public.pricing_rules(id) on delete set null,  -- referência; valores abaixo são snapshot
  currency                    text not null default 'BRL',
  base_cents                  bigint not null check (base_cents >= 0),
  distance_component_cents    bigint not null check (distance_component_cents >= 0),
  vehicle_component_cents     bigint not null check (vehicle_component_cents >= 0),
  urgency_component_cents     bigint not null check (urgency_component_cents >= 0),
  dynamic_component_cents     bigint not null check (dynamic_component_cents >= 0),
  subtotal_cents              bigint not null check (subtotal_cents >= 0),
  platform_fee_cents          bigint not null check (platform_fee_cents >= 0),
  driver_offer_cents          bigint not null check (driver_offer_cents >= 0),
  customer_price_cents        bigint not null check (customer_price_cents >= 0),
  distance_meters             integer not null check (distance_meters >= 0),
  duration_seconds            integer not null check (duration_seconds >= 0),
  status                      quote_status not null default 'pending',
  expires_at                  timestamptz,
  confirmed_at                timestamptz,
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now()
);
create trigger trg_delivery_quotes_updated_at
  before update on public.delivery_quotes
  for each row execute function public.set_updated_at();
create index if not exists idx_delivery_quotes_request on public.delivery_quotes(delivery_request_id);