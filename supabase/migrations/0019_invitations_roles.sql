-- 0019_invitations_roles.sql
-- Convites + atribuição de papel (ADR-010, decisões D3 e D4).
--
-- Cria:
--  * enum invitation_status
--  * tabela invitations (RLS)
--  * helper my_email() (SECURITY DEFINER) — email do caller, para RLS/accept
--  * 6 RPCs SECURITY DEFINER (Modelo B) com authz interna via auth.uid():
--      create_invitation, accept_invitation, cancel_invitation,
--      assign_platform_role, add_org_member, create_driver
--  * grants least-privilege + RLS policies de invitations
--
-- Princípios (regra mestra + Modelo B, Sessão 04):
--  * authenticated recebe EXECUTE nas RPCs user-facing + SELECT em invitations (sob RLS).
--    NÃO recebe DML direto em invitations/user_platform_roles/organization_memberships/
--    drivers — toda mutação user-facing é via RPC DEFINER (defesa em profundidade).
--  * service_role (system-scoped, bypass RLS) mantém DML total.
--  * anon: nada (accept exige login; MVP sem superfície pública).
--  * Idempotência: accept_invitation não duplica memberships (on conflict do nothing);
--    aceitar 2x não reabre convite accepted.

set search_path = public, pg_catalog;

-- =========================================================================
-- Enum de status do convite.
-- =========================================================================
do $$ begin
  create type public.invitation_status as enum ('pending','accepted','cancelled','expired');
exception when duplicate_object then null; end $$;

-- =========================================================================
-- Tabela invitations.
-- role_type é texto com CHECK (não enum novo) para não duplicar platform_role/org_role.
-- business_* exigem organization_id; platform roles/driver exigem null.
-- =========================================================================
create table if not exists public.invitations (
  id                  uuid primary key default gen_random_uuid(),
  email               text not null,
  role_type           text not null,
  organization_id     uuid references public.organizations(id) on delete cascade,
  invited_by_user_id  uuid not null references public.profiles(id) on delete restrict,
  token               uuid not null unique default gen_random_uuid(),
  status              invitation_status not null default 'pending',
  expires_at          timestamptz not null default (now() + interval '7 days'),
  accepted_by_user_id uuid references public.profiles(id),
  accepted_at         timestamptz,
  driver_meta         jsonb,
  created_at          timestamptz not null default now(),
  constraint invitations_role_type_check
    check (role_type in ('super_admin','admin','operator','business_owner','business_user','driver')),
  constraint invitations_org_presence_check
    check (
      (role_type in ('business_owner','business_user') and organization_id is not null)
      or (role_type in ('super_admin','admin','operator','driver') and organization_id is null)
    )
);

create index if not exists idx_invitations_email on public.invitations(email);
create index if not exists idx_invitations_status on public.invitations(status);
create index if not exists idx_invitations_token on public.invitations(token);

alter table public.invitations enable row level security;

comment on table public.invitations is
  'Convites de usuário (ADR-010 D3). Mutação só via RPC DEFINER; leitura via RLS (próprio/admin).';

-- =========================================================================
-- Helper my_email(): email do caller (auth.uid). SECURITY DEFINER para ler auth.users
-- (authenticated não tem SELECT em auth.users). Usado em RLS de invitations e em
-- accept_invitation (prova propriedade do email via login).
-- =========================================================================
create or replace function public.my_email()
returns text
language sql
security definer
stable
set search_path = public, pg_catalog, auth
as $$
  select a.email from auth.users a where a.id = auth.uid();
$$;

comment on function public.my_email() is
  'Email do caller (SECURITY DEFINER, ADR-010 D3). Para RLS de invitations e prova de propriedade em accept_invitation.';

grant execute on function public.my_email() to authenticated, service_role;

-- =========================================================================
-- is_super_or_admin(): caller é super_admin ou admin (NÃO operator).
-- Usada para AUTORIDADE DE MUTAÇÃO em convites/papéis (assign_platform_role,
-- create_driver, cancel_invitation alheio, add_org_member via platform path).
-- Rationale (ADR-009 vs ADR-010 D7): operator tem visibilidade cross-tenant
-- (is_platform_admin, ADR-009) mas NÃO tem autoridade de gestão de usuários
-- (não convida, não atribui papel, não provisiona driver). is_platform_admin()
-- inclui operator (visibilidade); is_super_or_admin() exclui (autoridade).
-- =========================================================================
create or replace function public.is_super_or_admin()
returns boolean
language sql
security definer
stable
set search_path = public, pg_catalog
as $$
  select exists (
    select 1 from public.user_platform_roles r
    where r.user_id = auth.uid()
      and r.role in ('super_admin','admin')
  );
$$;

comment on function public.is_super_or_admin() is
  'True se caller é super_admin ou admin (exclui operator). Autoridade de mutação em convites/papéis (ADR-010 D7). is_platform_admin() inclui operator (visibilidade, ADR-009); esta exclui.';

grant execute on function public.is_super_or_admin() to authenticated, service_role;

-- =========================================================================
-- create_invitation: inviter autorizado cria convite pending + token.
-- NÃO cria auth.users (signup via Supabase Auth Admin API no backend).
-- Idempotente: se já existe convite pending para (email, role_type, organization_id),
-- devolve o token existente em vez de duplicar.
-- =========================================================================
create or replace function public.create_invitation(
  p_email          text,
  p_role_type      text,
  p_organization_id uuid default null,
  p_driver_meta    jsonb default null
) returns table(ok boolean, reason text, token uuid)
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_caller  uuid := auth.uid();
  v_is_super boolean;
  v_is_admin boolean;
  v_ok      boolean := false;
  v_token   uuid;
begin
  if v_caller is null then
    return query select false, 'not_authorized', null::uuid; return;
  end if;

  if p_email is null or p_email = '' then
    return query select false, 'invalid_email', null::uuid; return;
  end if;

  if not (p_role_type in ('super_admin','admin','operator','business_owner','business_user','driver')) then
    return query select false, 'invalid_role_type', null::uuid; return;
  end if;

  -- Consistência org_id vs role_type (igual ao CHECK, validado cedo).
  if (p_role_type in ('business_owner','business_user')) and p_organization_id is null then
    return query select false, 'org_required', null::uuid; return;
  end if;
  if (p_role_type in ('super_admin','admin','operator','driver')) and p_organization_id is not null then
    return query select false, 'org_not_allowed', null::uuid; return;
  end if;

  select
    exists(select 1 from public.user_platform_roles r where r.user_id=v_caller and r.role='super_admin'),
    exists(select 1 from public.user_platform_roles r where r.user_id=v_caller and r.role in ('super_admin','admin'))
    into v_is_super, v_is_admin;

  case p_role_type
    when 'super_admin' then v_ok := v_is_super;
    when 'admin'        then v_ok := v_is_super;
    when 'operator'     then v_ok := v_is_admin;
    when 'driver'       then v_ok := v_is_admin;
    when 'business_owner' then v_ok := v_is_super;  -- nova org: só super_admin
    when 'business_user' then
      v_ok := v_is_admin  -- super/admin
        or exists (
          select 1 from public.organization_memberships m
          where m.user_id = v_caller
            and m.organization_id = p_organization_id
            and m.role = 'business_owner'
        );
    else v_ok := false;
  end case;

  if not v_ok then
    return query select false, 'not_authorized', null::uuid; return;
  end if;

  -- Idempotência: convite pending existente para mesmo (email, role_type, organization_id).
  select i.token into v_token
  from public.invitations i
  where i.email = p_email
    and i.role_type = p_role_type
    and (i.organization_id is not distinct from p_organization_id)
    and i.status = 'pending';
  if v_token is not null then
    return query select true, 'already_pending', v_token; return;
  end if;

  insert into public.invitations as inv
    (email, role_type, organization_id, invited_by_user_id, driver_meta)
  values
    (p_email, p_role_type, p_organization_id, v_caller, p_driver_meta)
  returning inv.token into v_token;

  return query select true, 'created', v_token;
end;
$$;

comment on function public.create_invitation(text,text,uuid,jsonb) is
  'Cria convite pending (SECURITY DEFINER, ADR-010 D3). Autorização por papel do inviter (matriz ADR-010 D7). Idempotente (pending existente devolve token).';

-- =========================================================================
-- accept_invitation: convidado autenticado cujo email casa com o convite.
-- Aplica o papel idempotentemente; marca accepted. Não reabre convite já accepted.
-- =========================================================================
create or replace function public.accept_invitation(
  p_token uuid
) returns table(ok boolean, reason text, applied_role text)
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_caller  uuid := auth.uid();
  v_email   text;
  v_inv     public.invitations%rowtype;
  v_drv_id  uuid;
begin
  if v_caller is null then
    return query select false, 'not_authorized', null::text; return;
  end if;

  select a.email into v_email from auth.users a where a.id = v_caller;
  if v_email is null then
    return query select false, 'caller_not_found', null::text; return;
  end if;

  select * into v_inv from public.invitations where token = p_token for update;

  if not found then
    return query select false, 'invitation_not_found', null::text; return;
  end if;

  -- Prova de propriedade do email: o login (Supabase Auth) confirmou o email.
  if v_inv.email <> v_email then
    return query select false, 'not_authorized', null::text; return;
  end if;

  if v_inv.status = 'accepted' then
    return query select false, 'already_accepted', null::text; return;
  end if;
  if v_inv.status = 'cancelled' then
    return query select false, 'cancelled', null::text; return;
  end if;
  if v_inv.status <> 'pending' then
    return query select false, 'not_pending', null::text; return;
  end if;
  if v_inv.expires_at < now() then
    update public.invitations set status = 'expired' where id = v_inv.id;
    return query select false, 'expired', null::text; return;
  end if;

  -- Aplica o papel (idempotente — on conflict do nothing; primeiro papel vence).
  case v_inv.role_type
    when 'super_admin','admin','operator' then
      insert into public.user_platform_roles (user_id, role)
      values (v_caller, v_inv.role_type::public.platform_role)
      on conflict (user_id) do nothing;

    when 'business_owner','business_user' then
      insert into public.organization_memberships (user_id, organization_id, role)
      values (v_caller, v_inv.organization_id, v_inv.role_type::public.org_role)
      on conflict (user_id, organization_id) do nothing;

    when 'driver' then
      insert into public.drivers (user_id, full_name, phone)
      values (
        v_caller,
        coalesce(v_inv.driver_meta ->> 'full_name', (select p.full_name from public.profiles p where p.id = v_caller), ''),
        coalesce(v_inv.driver_meta ->> 'phone',      (select p.phone      from public.profiles p where p.id = v_caller), '')
      )
      on conflict (user_id) do nothing
      returning id into v_drv_id;

    else
      return query select false, 'invalid_role_type', null::text; return;
  end case;

  update public.invitations
    set status = 'accepted', accepted_by_user_id = v_caller, accepted_at = now()
    where id = v_inv.id;

  return query select true, 'accepted', v_inv.role_type;
end;
$$;

comment on function public.accept_invitation(uuid) is
  'Aceita convite (SECURITY DEFINER, ADR-010 D3). Exige login + email casa com convite. Aplica papel idempotentemente (on conflict do nothing).';

-- =========================================================================
-- cancel_invitation: inviter ou super_admin/admin. Só pending -> cancelled.
-- (operator NÃO cancela convite alheio — is_super_or_admin, não is_platform_admin.)
-- =========================================================================
create or replace function public.cancel_invitation(
  p_invitation_id uuid
) returns table(ok boolean, reason text)
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_caller uuid := auth.uid();
  v_inv    public.invitations%rowtype;
begin
  if v_caller is null then
    return query select false, 'not_authorized'; return;
  end if;

  select * into v_inv from public.invitations where id = p_invitation_id for update;
  if not found then
    return query select false, 'not_found'; return;
  end if;

  if v_inv.invited_by_user_id <> v_caller and not public.is_super_or_admin() then
    return query select false, 'not_authorized'; return;
  end if;

  if v_inv.status <> 'pending' then
    return query select false, 'not_pending'; return;
  end if;

  update public.invitations set status = 'cancelled' where id = p_invitation_id;
  return query select true, 'cancelled';
end;
$$;

comment on function public.cancel_invitation(uuid) is
  'Cancela convite pending (SECURITY DEFINER, ADR-010 D3). Inviter ou super_admin/admin (is_super_or_admin).';

-- =========================================================================
-- assign_platform_role: super_admin/admin atribui papel platform (idempotente upsert).
-- (operator NÃO atribui papel — is_super_or_admin, não is_platform_admin.)
-- =========================================================================
create or replace function public.assign_platform_role(
  p_user_id uuid,
  p_role    public.platform_role
) returns table(ok boolean, reason text)
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_caller uuid := auth.uid();
begin
  if v_caller is null or not public.is_super_or_admin() then
    return query select false, 'not_authorized'; return;
  end if;

  if not exists (select 1 from public.profiles p where p.id = p_user_id) then
    return query select false, 'profile_not_found'; return;
  end if;

  insert into public.user_platform_roles (user_id, role)
  values (p_user_id, p_role)
  on conflict (user_id) do update set role = excluded.role, assigned_at = now();

  return query select true, 'assigned';
end;
$$;

comment on function public.assign_platform_role(uuid,platform_role) is
  'Atribui papel platform (SECURITY DEFINER, ADR-010 D4). Platform admin apenas. Idempotente (upsert).';

-- =========================================================================
-- add_org_member: super_admin/admin (platform path) ou business_owner da própria org.
-- =========================================================================
create or replace function public.add_org_member(
  p_user_id        uuid,
  p_organization_id uuid,
  p_role           public.org_role
) returns table(ok boolean, reason text)
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_caller uuid := auth.uid();
  v_ok     boolean;
begin
  if v_caller is null then
    return query select false, 'not_authorized'; return;
  end if;

  v_ok := public.is_super_or_admin()
    or exists (
      select 1 from public.organization_memberships m
      where m.user_id = v_caller
        and m.organization_id = p_organization_id
        and m.role = 'business_owner'
    );

  if not v_ok then
    return query select false, 'not_authorized'; return;
  end if;

  if not exists (select 1 from public.profiles p where p.id = p_user_id) then
    return query select false, 'profile_not_found'; return;
  end if;

  insert into public.organization_memberships (user_id, organization_id, role)
  values (p_user_id, p_organization_id, p_role)
  on conflict (user_id, organization_id) do update set role = excluded.role;

  return query select true, 'added';
end;
$$;

comment on function public.add_org_member(uuid,uuid,org_role) is
  'Adiciona/atualiza membro de org (SECURITY DEFINER, ADR-010 D4). Admin ou business_owner da própria org. Idempotente.';

-- =========================================================================
-- create_driver: super_admin/admin provisiona driver (account_status default pending).
-- (operator NÃO provisiona driver — is_super_or_admin.)
-- =========================================================================
create or replace function public.create_driver(
  p_user_id  uuid,
  p_full_name text,
  p_phone    text
) returns table(ok boolean, reason text, driver_id uuid)
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_caller uuid := auth.uid();
  v_id     uuid;
begin
  if v_caller is null or not public.is_super_or_admin() then
    return query select false, 'not_authorized', null::uuid; return;
  end if;

  if not exists (select 1 from public.profiles p where p.id = p_user_id) then
    return query select false, 'profile_not_found', null::uuid; return;
  end if;

  if p_full_name is null or p_full_name = '' or p_phone is null or p_phone = '' then
    return query select false, 'invalid_meta', null::uuid; return;
  end if;

  insert into public.drivers (user_id, full_name, phone)
  values (p_user_id, p_full_name, p_phone)
  on conflict (user_id) do nothing
  returning id into v_id;

  if v_id is null then
    select id into v_id from public.drivers where user_id = p_user_id;
    return query select true, 'already_exists', v_id; return;
  end if;

  return query select true, 'created', v_id;
end;
$$;

comment on function public.create_driver(uuid,text,text) is
  'Provisiona driver (SECURITY DEFINER, ADR-010 D4). Platform admin apenas. Idempotente (já existe -> ok).';

-- =========================================================================
-- Grants (least-privilege, Modelo B).
-- authenticated: EXECUTE nas 6 RPCs + SELECT em invitations (sob RLS). Sem DML direto.
-- service_role: EXECUTE nas 6 + DML total em invitations.
-- =========================================================================
revoke all on function
  public.create_invitation(text,text,uuid,jsonb),
  public.accept_invitation(uuid),
  public.cancel_invitation(uuid),
  public.assign_platform_role(uuid,public.platform_role),
  public.add_org_member(uuid,uuid,public.org_role),
  public.create_driver(uuid,text,text)
from public;

grant execute on function
  public.create_invitation(text,text,uuid,jsonb),
  public.accept_invitation(uuid),
  public.cancel_invitation(uuid),
  public.assign_platform_role(uuid,public.platform_role),
  public.add_org_member(uuid,uuid,public.org_role),
  public.create_driver(uuid,text,text)
to service_role, authenticated;

grant select, insert, update, delete on public.invitations to service_role;
grant select on public.invitations to authenticated;
-- Nenhum DML a authenticated em invitations (mutação só via RPC DEFINER).
-- Nenhum grant a anon.

-- =========================================================================
-- RLS de invitations.
-- SELECT: inviter vê os que criou; convidado vê os seus (por email); platform admin vê tudo.
-- INSERT/UPDATE/DELETE: sem policy para authenticated -> default-deny (mutação via RPC).
-- =========================================================================
drop policy if exists invitations_sel on public.invitations;
create policy invitations_sel on public.invitations
  for select to authenticated
  using (
    public.is_platform_admin()
    or invited_by_user_id = auth.uid()
    or email = public.my_email()
  );

-- =========================================================================
-- Registro da postura.
-- =========================================================================
comment on schema public is
  'ViO10: schema de domínio. Sessão 05 (ADR-010): ciclo de vida de identidade — handle_new_user (0018) garante profiles; invitations + 6 RPCs DEFINER (0019) para convite/atribuição de papel, idempotentes, authz por auth.uid(); RLS em invitations (inviter/convidado/admin); anon sem grant; authenticated sem DML direto em invitations (mutação só via RPC).';