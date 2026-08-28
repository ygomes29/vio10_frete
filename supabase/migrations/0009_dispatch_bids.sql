-- 0009_dispatch_bids.sql
-- Dispatch e Bids. ADR-006: ACEITAR != GANHAR. A rodada coleta respostas; a seleção
-- e o claim atômico acontecem ao fechar (ver 0011_rpcs.sql).

-- dispatch_rounds: janela real de disputa. Parâmetros são snapshot.
create table if not exists public.dispatch_rounds (
  id                  uuid primary key default gen_random_uuid(),
  delivery_request_id uuid not null references public.delivery_requests(id) on delete restrict,
  round_number        integer not null check (round_number > 0),
  status              dispatch_round_status not null default 'open',
  search_radius_m     integer not null check (search_radius_m > 0),
  max_candidates      integer not null check (max_candidates > 0),
  driver_offer_cents  bigint not null check (driver_offer_cents >= 0),
  config_snapshot     jsonb not null default '{}'::jsonb,  -- snapshot da config usada
  opened_at           timestamptz not null default now(),
  expires_at         timestamptz not null,
  closed_at          timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint dispatch_rounds_request_round_uk unique (delivery_request_id, round_number),
  constraint dispatch_rounds_expires_after_open check (expires_at > opened_at)
);
create trigger trg_dispatch_rounds_updated_at
  before update on public.dispatch_rounds
  for each row execute function public.set_updated_at();
create index if not exists idx_dispatch_rounds_request on public.dispatch_rounds(delivery_request_id);
create index if not exists idx_dispatch_rounds_status   on public.dispatch_rounds(status) where status = 'open';

-- delivery_offers: uma oferta a um entregador numa rodada.
create table if not exists public.delivery_offers (
  id                  uuid primary key default gen_random_uuid(),
  delivery_request_id uuid not null references public.delivery_requests(id) on delete restrict,  -- denormalizado para query/event
  dispatch_round_id   uuid not null references public.dispatch_rounds(id) on delete restrict,
  driver_id           uuid not null references public.drivers(id) on delete restrict,
  driver_offer_cents  bigint not null check (driver_offer_cents >= 0),
  status              delivery_offer_status not null default 'pending',
  expires_at          timestamptz not null,
  created_at          timestamptz not null default now(),
  responded_at        timestamptz,
  updated_at          timestamptz not null default now(),
  constraint delivery_offers_round_driver_uk unique (dispatch_round_id, driver_id),
  -- FK composta para garantir que bids referenciem offer+driver coerentes (ver bids):
  constraint delivery_offers_id_driver_uk unique (id, driver_id)
);
create trigger trg_delivery_offers_updated_at
  before update on public.delivery_offers
  for each row execute function public.set_updated_at();
create index if not exists idx_delivery_offers_round   on public.delivery_offers(dispatch_round_id);
create index if not exists idx_delivery_offers_driver on public.delivery_offers(driver_id);
create index if not exists idx_delivery_offers_status  on public.delivery_offers(status) where status in ('pending','accepted','counter_bid');

-- bids: resposta de um entregador a uma oferta. Uma resposta válida por (offer, driver).
-- accept  -> bid_amount_cents = driver_offer_cents (participa da seleção pelo valor ofertado)
-- counter_bid -> bid_amount_cents = valor proposto
-- decline  -> bid_amount_cents = NULL (não participa da seleção)
create table if not exists public.bids (
  id                  uuid primary key default gen_random_uuid(),
  delivery_offer_id   uuid not null,
  driver_id           uuid not null,
  delivery_request_id uuid not null references public.delivery_requests(id) on delete restrict,  -- denormalizado
  response_type       bid_response_type not null,
  bid_amount_cents    bigint check (
    (response_type in ('accept','counter_bid') and bid_amount_cents is not null and bid_amount_cents > 0)
    or (response_type = 'decline' and bid_amount_cents is null)
  ),
  idempotency_key     text,
  correlation_id      uuid default gen_random_uuid(),
  created_at          timestamptz not null default now(),
  -- FK composta: bid.driver_id deve bater com offer.driver_id (proteção contra associar
  -- bid a offer de outro driver).
  constraint bids_offer_driver_fk
    foreign key (delivery_offer_id, driver_id)
    references public.delivery_offers(id, driver_id) on delete restrict,
  constraint bids_offer_driver_uk unique (delivery_offer_id, driver_id),
  constraint bids_idempotency_uk  unique (idempotency_key)  -- idempotência global por chave
);
create index if not exists idx_bids_offer  on public.bids(delivery_offer_id);
create index if not exists idx_bids_driver on public.bids(driver_id);