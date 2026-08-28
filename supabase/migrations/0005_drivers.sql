-- 0005_drivers.sql
-- Entregadores, veículos, documentos, disponibilidade e localização.
set search_path to public, extensions;
-- Drivers são PLATFORM-SCOPED: sem organization_id.

-- drivers: 1:1 com profiles.
create table if not exists public.drivers (
  id                          uuid primary key default gen_random_uuid(),
  user_id                     uuid not null unique references public.profiles(id) on delete restrict,
  full_name                   text not null,
  phone                       text not null,
  account_status              driver_account_status not null default 'pending',
  current_vehicle_id          uuid,  -- FK adicionada após vehicles (abaixo)
  current_availability_status driver_availability_status not null default 'offline',
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now()
);
create trigger trg_drivers_updated_at
  before update on public.drivers
  for each row execute function public.set_updated_at();
create index if not exists idx_drivers_availability
  on public.drivers(current_availability_status);

-- vehicles: 1:N (um entregador pode ter vários, usa um por vez).
create table if not exists public.vehicles (
  id          uuid primary key default gen_random_uuid(),
  driver_id   uuid not null references public.drivers(id) on delete cascade,
  vehicle_type vehicle_type not null,
  plate       text not null,
  model       text,
  capacity_kg integer check (capacity_kg is null or capacity_kg > 0),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create trigger trg_vehicles_updated_at
  before update on public.vehicles
  for each row execute function public.set_updated_at();
create index if not exists idx_vehicles_driver on public.vehicles(driver_id);

-- FK tardia: drivers.current_vehicle_id -> vehicles (evita ciclo na criação).
do $$ begin
  alter table public.drivers
    add constraint drivers_current_vehicle_fk
    foreign key (current_vehicle_id) references public.vehicles(id) on delete set null;
exception when duplicate_object then null; end $$;

-- driver_documents: apenas metadados/referência. Binário fica no Supabase Storage.
create table if not exists public.driver_documents (
  id            uuid primary key default gen_random_uuid(),
  driver_id     uuid not null references public.drivers(id) on delete cascade,
  document_type document_type not null,
  storage_path  text not null,                 -- path no Storage (policies privadas)
  status        text not null default 'pending',
  expires_at    timestamptz,
  verified_at   timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create trigger trg_driver_documents_updated_at
  before update on public.driver_documents
  for each row execute function public.set_updated_at();
create index if not exists idx_driver_documents_driver on public.driver_documents(driver_id);

-- driver_availability: log append-only de mudanças de disponibilidade (auditoria).
-- O estado atual vive em drivers.current_availability_status (filtro rápido).
create table if not exists public.driver_availability (
  id          uuid primary key default gen_random_uuid(),
  driver_id   uuid not null references public.drivers(id) on delete restrict,
  status      driver_availability_status not null,
  reason      text,
  changed_at  timestamptz not null default now()
);
create index if not exists idx_driver_availability_driver
  on public.driver_availability(driver_id, changed_at desc);

-- driver_locations: posição ATUAL (1:1 por driver, upsert). History fica para depois.
create table if not exists public.driver_locations (
  driver_id    uuid primary key references public.drivers(id) on delete cascade,
  position     geography(Point, 4326),
  accuracy_m   real,
  heading_deg  real,
  speed_mps    real,
  captured_at  timestamptz not null,            -- timestamp do dispositivo
  received_at  timestamptz not null default now(),
  constraint driver_locations_position_check
    check (position is not null)
);
create index if not exists idx_driver_locations_position
  on public.driver_locations using gist (position);
-- "stale" é conceito derivado (captured_at antigo); não há coluna. Ver GEOLOCATION.md.