-- 0004_identity_tenancy.sql
-- Identidade e tenancy.
-- PostGIS vive no schema `extensions`; o runner de migrations não o inclui no
-- search_path por padrão, então qualificamos o caminho explicitamente aqui.
set search_path to public, extensions;
-- Papéis PLATFORM-SCOPED (super_admin/admin/operator) vivem em user_platform_roles
-- e NÃO pertencem a nenhuma organization. Drivers também são platform-scoped (sem org).
-- Papéis ORG-SCOPED (business_owner/business_user) vivem em organization_memberships.
-- Nenhuma gambiarra de "organization fictícia ViO10".

-- profiles: 1:1 com auth.users. Não duplica auth.users; apenas perfis públicos.
create table if not exists public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  full_name    text,
  phone        text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create trigger trg_profiles_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- organizations: tenant / conta contratante. Limite primário de RLS.
create table if not exists public.organizations (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  legal_name   text,
  document     text,                -- CNPJ quando aplicável
  status       text not null default 'active',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create trigger trg_organizations_updated_at
  before update on public.organizations
  for each row execute function public.set_updated_at();

-- businesses: negócio/marca operado pela organization.
create table if not exists public.businesses (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  name            text not null,
  status          text not null default 'active',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create trigger trg_businesses_updated_at
  before update on public.businesses
  for each row execute function public.set_updated_at();

-- business_locations: unidade física. Endereço atual vivem aqui; snapshots
-- operacionais ficam em delivery_requests.
create table if not exists public.business_locations (
  id              uuid primary key default gen_random_uuid(),
  business_id     uuid not null references public.businesses(id) on delete restrict,
  label           text,                    -- ex.: "Matriz", "Filial centro"
  address         text not null,
  latitude        double precision,        -- derivado/auxiliar para API/UI
  longitude       double precision,
  point           geography(Point, 4326),  -- fonte de verdade espacial
  contact_name    text,
  contact_phone   text,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint business_locations_latlng_check
    check ((latitude is null) = (longitude is null))
);
create trigger trg_business_locations_updated_at
  before update on public.business_locations
  for each row execute function public.set_updated_at();
create index if not exists idx_business_locations_business_id
  on public.business_locations(business_id);
create index if not exists idx_business_locations_point
  on public.business_locations using gist (point);

-- user_platform_roles: 1:1 usuário->papel global. Platform-scoped, sem organization.
create table if not exists public.user_platform_roles (
  user_id     uuid primary key references public.profiles(id) on delete cascade,
  role        platform_role not null,
  assigned_at timestamptz not null default now()
);

-- organization_memberships: usuário pertence a N organizations com um papel.
create table if not exists public.organization_memberships (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references public.profiles(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  role            org_role not null,
  created_at      timestamptz not null default now(),
  constraint organization_memberships_user_org_uk unique (user_id, organization_id)
);
create index if not exists idx_org_memberships_org on public.organization_memberships(organization_id);