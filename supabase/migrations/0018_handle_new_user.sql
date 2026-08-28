-- 0018_handle_new_user.sql
-- Ciclo de vida de identidade: garante que toda linha em auth.users tenha uma
-- linha correspondente em public.profiles (ADR-010, decisão D2).
--
-- Por que trigger (e não "backend cria perfil"): user_platform_roles,
-- organization_memberships e drivers têm FK references profiles(id). Sem o perfil,
-- a primeira atribuição de papel/membership/driver viola FK. Confiar no backend lembrar
-- de criar o perfil em todo signup/convite é frágil. O trigger garante a consistência
-- independentemente do caminho (signup direto, convite aceito, provisionamento admin).
-- O perfil nasce vazio (full_name/phone do raw_user_meta_data se houver) e é preenchido
-- depois. O trigger NÃO atribui papel/membership/driver — isso é ato explícito via
-- 0019 (accept_invitation / RPCs admin). Ver ADR-010.
--
-- Padrão oficial Supabase. Função SECURITY DEFINER roda como owner (postgres) para poder
-- inserir em public.profiles (o insert em auth.users acontece como o serviço de auth,
-- que não tem INSERT em public.profiles). search_path fixo por segurança.

set search_path = public, pg_catalog;

-- =========================================================================
-- handle_new_user: cria row em profiles espelhando auth.users.id.
-- on conflict (id) do nothing -> idempotente: se o perfil já existir (re-insert,
-- provisionamento manual prévio), não duplica nem erro.
-- =========================================================================
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
begin
  insert into public.profiles (id, full_name, phone)
  values (
    new.id,
    new.raw_user_meta_data ->> 'full_name',
    new.raw_user_meta_data ->> 'phone'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

comment on function public.handle_new_user() is
  'Cria linha em profiles ao inserir auth.users (SECURITY DEFINER, ADR-010 D2). Idempotente (on conflict do nothing). Não atribui papel.';

-- =========================================================================
-- Trigger on auth.users AFTER INSERT.
-- =========================================================================
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- EXECUTE: a função é DEFINER; qualquer role que dispare o trigger (o serviço de auth
-- roda como postgres/owner) pode invocar. Concedemos a authenticated/anon/service_role
-- para garantir que o path de signup (que pode rodar sob diferentes roles) sempre crie o
-- perfil. A autorização real é o próprio evento de INSERT em auth.users (controlado por
-- Supabase Auth), não a chamada direta da função.
grant execute on function public.handle_new_user() to authenticated, anon, service_role;

-- Nota: `comment on trigger ... on auth.users` exigiria ownership de auth.users
-- (postgres não é owner — o dono é supabase_auth_admin). Por isso o comentário do
-- trigger é omitido; a semântica vive no comment on function acima e no ADR-010 D2.