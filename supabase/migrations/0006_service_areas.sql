-- 0006_service_areas.sql
-- Áreas operacionais. MVP: Congonhas/MG, mas a cidade NÃO é hardcoded no domínio
set search_path to public, extensions;
-- (vive como dado aqui). Usado para eligibility do entregador e raio base.

create table if not exists public.service_areas (
  id                 uuid primary key default gen_random_uuid(),
  name               text not null,
  city               text not null,                 -- ex.: "Congonhas", "MG"
  is_active          boolean not null default true,
  center             geography(Point, 4326) not null,
  default_radius_m   integer not null check (default_radius_m > 0),
  geometry           geography(Polygon, 4326),      -- contorno da área (opcional)
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create trigger trg_service_areas_updated_at
  before update on public.service_areas
  for each row execute function public.set_updated_at();
create index if not exists idx_service_areas_center
  on public.service_areas using gist (center);
create index if not exists idx_service_areas_geometry
  on public.service_areas using gist (geometry);