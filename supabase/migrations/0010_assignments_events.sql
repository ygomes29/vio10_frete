-- 0010_assignments_events.sql
-- Atribuição (invariante crítica) e eventos de auditoria.

-- delivery_assignments: UMA ativa por delivery_request (partial unique index).
create table if not exists public.delivery_assignments (
  id                  uuid primary key default gen_random_uuid(),
  delivery_request_id uuid not null references public.delivery_requests(id) on delete restrict,
  driver_id           uuid not null references public.drivers(id) on delete restrict,
  dispatch_round_id   uuid references public.dispatch_rounds(id) on delete restrict,
  delivery_offer_id   uuid references public.delivery_offers(id) on delete restrict,
  bid_id              uuid references public.bids(id) on delete restrict,
  status              assignment_status not null default 'active',
  assigned_at         timestamptz not null default now(),
  ended_at            timestamptz,
  ended_reason        text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create trigger trg_delivery_assignments_updated_at
  before update on public.delivery_assignments
  for each row execute function public.set_updated_at();

-- Invariante crítica (ADR-007): no máximo UMA assignment ativa por delivery_request.
create unique index if not exists idx_delivery_assignments_active_uk
  on public.delivery_assignments(delivery_request_id) where status = 'active';

create index if not exists idx_delivery_assignments_driver  on public.delivery_assignments(driver_id);
create index if not exists idx_delivery_assignments_request on public.delivery_assignments(delivery_request_id);

-- delivery_events: timeline/auditoria imutável. Não é event sourcing; estado vive nas
-- tabelas principais. Trigger impede update/delete.
create table if not exists public.delivery_events (
  id                  uuid primary key default gen_random_uuid(),
  delivery_request_id uuid not null references public.delivery_requests(id) on delete restrict,
  event_type          delivery_event_type not null,
  actor_type          text not null default 'system',
  actor_id            uuid,
  from_status         delivery_status,
  to_status           delivery_status,
  metadata            jsonb not null default '{}'::jsonb,
  correlation_id      uuid default gen_random_uuid(),
  created_at          timestamptz not null default now()
);
create index if not exists idx_delivery_events_request
  on public.delivery_events(delivery_request_id, created_at);
create index if not exists idx_delivery_events_correlation
  on public.delivery_events(correlation_id) where correlation_id is not null;

-- Imutabilidade: bloqueia update e delete.
create or replace function public.enforce_delivery_events_immutable()
returns trigger
language plpgsql
set search_path = public, pg_catalog
as $$
begin
  raise exception 'delivery_events é imutável (append-only): operação % não permitida', tg_op;
end;
$$;
drop trigger if exists trg_delivery_events_no_update on public.delivery_events;
create trigger trg_delivery_events_no_update
  before update on public.delivery_events
  for each row execute function public.enforce_delivery_events_immutable();
drop trigger if exists trg_delivery_events_no_delete on public.delivery_events;
create trigger trg_delivery_events_no_delete
  before delete on public.delivery_events
  for each row execute function public.enforce_delivery_events_immutable();