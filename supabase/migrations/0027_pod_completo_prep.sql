-- 0027_pod_completo_prep.sql
-- Sessão 12 (ADR-017) — preparação de schema para POD completo (OTP do recebedor,
-- gate de geolocalização, gate de pickup POD, bucket Storage pod-photos).
-- SEM funções que referenciem o novo enum aqui (gotcha: ALTER TYPE ... ADD VALUE não é
-- referenciável na mesma transação — as RPCs que usam 'otp_generated' vivem em 0028,
-- transação separada). Mesmo padrão de split 0025/0026 (ADR-016 D9).
--
-- Changes:
--   1. add enum value 'otp_generated' to delivery_event_type.
--   2. create table delivery_otps (OTP do recebedor: hash salt+sha256, TTL, lockout).
--   3. index + RLS (SELECT p/ authenticated sob can_view_delivery_request) + grants.
--   4. helper is_assigned_driver_of(uuid) SECURITY DEFINER (usado pela policy de Storage;
--      bypassa RLS, evita recursão na policy de storage.objects).
--   5. bucket Storage 'pod-photos' (privado, 50MiB, png/jpeg).
--   6. RLS policy INSERT em storage.objects p/ authenticated (driver com assignment ativa).
-- Nenhuma coluna nova em proof_of_delivery (D7). Único acréscimo de tabela: delivery_otps.

-- 1. Novo tipo de evento de auditoria para geração de OTP (consumido em 0028).
alter type public.delivery_event_type add value if not exists 'otp_generated';

-- 2. Tabela dedicada ao ciclo de vida do OTP do recebedor (delivery-only; unique por corrida).
create table if not exists public.delivery_otps (
  id                  uuid primary key default gen_random_uuid(),
  delivery_request_id uuid not null references public.delivery_requests(id) on delete restrict,
  code_hash           text not null,                      -- sha256(code || salt) em hex
  salt                text not null,                      -- gen_random_bytes(8) em hex (por linha)
  expires_at          timestamptz not null,                -- now() + ttl_seconds
  attempts            int  not null default 0 check (attempts >= 0),
  max_attempts        int  not null default 5 check (max_attempts >= 1),
  consumed_at         timestamptz,                         -- setado no match (1 uso)
  generated_at        timestamptz not null default now(),  -- última geração/regeneração
  created_at          timestamptz not null default now(),
  unique (delivery_request_id)                            -- 1 OTP ativo por corrida (delivery-only)
);
create index if not exists idx_delivery_otps_request on public.delivery_otps(delivery_request_id);

-- 3. RLS + visibilidade (SELECT). Writes só via DEFINER (generate_delivery_otp em 0028).
alter table public.delivery_otps enable row level security;

drop policy if exists delivery_otps_sel on public.delivery_otps;
create policy delivery_otps_sel on public.delivery_otps
  for select to authenticated
  using (public.can_view_delivery_request(delivery_request_id));
-- sem INSERT/UPDATE/DELETE policy p/ authenticated (default-deny; write via DEFINER).

-- Grants: service_role (system-scoped, bypassa RLS) tudo; authenticated SELECT sob RLS; anon nada.
grant select on public.delivery_otps to authenticated;
grant all    on public.delivery_otps to service_role;
revoke all  on public.delivery_otps from anon;

-- 4. Helper: o caller (auth.uid) é o driver com assignment ATIVA na corrida dada?
-- SECURITY DEFINER para bypassar RLS dentro da policy de storage.objects (evita recursão
-- de RLS entre storage.objects e as tabelas de domínio). Usado apenas pela policy abaixo.
create or replace function public.is_assigned_driver_of(p_delivery_request_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public, pg_catalog
as $$
  select exists (
    select 1
    from public.delivery_assignments a
    join public.drivers d on d.id = a.driver_id
    where d.user_id = auth.uid()
      and a.delivery_request_id = p_delivery_request_id
      and a.status = 'active'
  )
$$;
revoke all on function public.is_assigned_driver_of(uuid) from public;
grant execute on function public.is_assigned_driver_of(uuid) to authenticated, service_role;

-- 5. Bucket Storage 'pod-photos' (privado; reads via URL assinada emitida pelo backend).
--    Guard on conflict do nothing para idempotência. Risco a verificar no replay: se o role
--    do Management API não puder insert em storage.buckets, o replay falha aqui — detectável.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('pod-photos', 'pod-photos', false, 52428800, array['image/png','image/jpeg'])
on conflict (id) do nothing;

-- 6. RLS INSERT em storage.objects p/ authenticated: path convencionado
--    pod-photos/{delivery_request_id}/{pod_type}/{uuid}.ext — só o driver com assignment
--    ativa naquela corrida pode gravar. Sem SELECT/UPDATE/DELETE p/ authenticated
--    (reads via URL assinada; default-deny otherwise).
--    Nota: storage.foldername(name) retorna os segmentos de pasta (sem o arquivo);
--    [1] = delivery_request_id.
drop policy if exists pod_photos_insert on storage.objects;
create policy pod_photos_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'pod-photos'
    and public.is_assigned_driver_of((storage.foldername(name))[1]::uuid)
  );

comment on table public.delivery_otps is
  'ViO10: ciclo de vida do OTP do recebedor (Sessão 12 / 0027, ADR-017 D1). Hash salt+sha256, TTL, lockout. Unique por delivery_request_id (delivery-only). Writes só via generate_delivery_otp (DEFINER, system-only, 0028).';