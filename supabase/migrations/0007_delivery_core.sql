-- 0007_delivery_core.sql
-- Núcleo da corrida: delivery_requests + delivery_items.
set search_path to public, extensions;
-- delivery_requests guarda SNAPSHOT de coleta/entrega (endereço, contatos, coords)
-- para que histórico não mude se a unidade for editada.

create table if not exists public.delivery_requests (
  id                 uuid primary key default gen_random_uuid(),
  organization_id    uuid not null references public.organizations(id) on delete restrict,
  business_id        uuid not null references public.businesses(id) on delete restrict,
  business_location_id uuid references public.business_locations(id) on delete set null,

  -- snapshot de coleta
  pickup_address     text not null,
  pickup_latitude    double precision not null,
  pickup_longitude   double precision not null,
  pickup_point       geography(Point, 4326) not null,
  pickup_contact_name text,
  pickup_contact_phone text not null,

  -- snapshot de entrega
  delivery_address   text not null,
  delivery_latitude  double precision not null,
  delivery_longitude double precision not null,
  delivery_point     geography(Point, 4326) not null,
  delivery_contact_name text,
  delivery_contact_phone text not null,

  vehicle_required   vehicle_type not null,
  priority           delivery_priority not null default 'standard',
  scheduled_at       timestamptz,                -- null = imediata
  origin             delivery_request_origin not null default 'dashboard',
  external_reference text,                       -- id do sistema de origem (idempotência externa)

  status             delivery_status not null default 'draft',
  reassignment_count integer not null default 0 check (reassignment_count >= 0),
  notes              text,
  instructions       text,

  -- timestamps operacionais
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  quoted_at              timestamptz,
  dispatch_started_at    timestamptz,
  assigned_at            timestamptz,
  pickup_arrived_at      timestamptz,
  picked_up_at           timestamptz,
  in_transit_at          timestamptz,
  delivered_at           timestamptz,
  cancelled_at           timestamptz,
  expired_at             timestamptz,
  cancelled_reason       text,
  failed_reason          text,

  constraint delivery_requests_external_ref_uk
    unique (organization_id, external_reference)
);
create trigger trg_delivery_requests_updated_at
  before update on public.delivery_requests
  for each row execute function public.set_updated_at();
create index if not exists idx_delivery_requests_org        on public.delivery_requests(organization_id);
create index if not exists idx_delivery_requests_business   on public.delivery_requests(business_id);
create index if not exists idx_delivery_requests_status     on public.delivery_requests(status);
create index if not exists idx_delivery_requests_pickup_point on public.delivery_requests using gist (pickup_point);
-- R17: external_reference ≠ idempotency_key (conceitos distintos — ver docs/SECURITY.md).
-- external_reference = id do REGISTRO no sistema de origem externa (vínculo, não retry).
--   UNIQUE por organization_id: uma org não cria 2 corridas p/ o mesmo pedido externo.
--   Pode ser NULL (corridas criadas direto no ViO10).
-- idempotency_key (em integration_events/bids/notifications) = chave de RETRY da operação.
-- external_reference pode ser null (permite múltiplas nulls mesmo com unique, por comportamento SQL).
-- Para garantir idempotência quando external_reference é null, usa-se idempotency_key via integration_events.

-- delivery_items: 1:N.
create table if not exists public.delivery_items (
  id                  uuid primary key default gen_random_uuid(),
  delivery_request_id uuid not null references public.delivery_requests(id) on delete restrict,
  description         text not null,
  quantity            integer not null check (quantity > 0),
  weight_g            integer check (weight_g is null or weight_g > 0),
  length_cm            integer check (length_cm is null or length_cm > 0),
  width_cm             integer check (width_cm is null or width_cm > 0),
  height_cm           integer check (height_cm is null or height_cm > 0),
  notes               text,
  created_at          timestamptz not null default now()
);
create index if not exists idx_delivery_items_request on public.delivery_items(delivery_request_id);