-- test_vio10_auth_lifecycle.sql — Ciclo de vida de identidade/convite (Sessão 05, ADR-010).
-- Valida: handle_new_user (0018), convites + atribuição de papel (0019), authz por
-- papel do inviter, idempotência de accept, prova de propriedade de email, expiração,
-- driver via convite, RLS de invitations, anon bloqueado.
--
-- Executa em begin/rollback (clean-slate). Fase 1 (owner): setup + testes do trigger.
-- Fase 2 (authenticated): simula usuários via set_config('request.jwt.claims', sub=uuid).
-- Resultados consolidados em al_results(test, expected, actual, pass). 34 asserções.

set search_path to public, extensions;
begin;

create temp table al_ids(k text primary key, v uuid);
create temp table al_results(test text, expected text, actual text, pass boolean);

-- ============================ FASE 1: SETUP (owner) ============================
do $$
declare
  v_orgA uuid; v_orgB uuid;
  v_uSuper uuid; v_uAdmin uuid; v_uOpRole uuid; v_uBO uuid;
  v_uOp uuid; v_uBU uuid; v_uDrv uuid; v_uOther uuid; v_uExp uuid;
  v_uTrig uuid; v_uTrig2 uuid;
begin
  insert into public.organizations(name) values('OrgA') returning id into v_orgA;
  insert into public.organizations(name) values('OrgB') returning id into v_orgB;

  -- Usuários via auth.users; a trigger handle_new_user (0018) cria profiles.
  -- uTrig traz raw_user_meta_data (teste explícito do trigger em T1).
  v_uSuper := gen_random_uuid(); insert into auth.users(id,email) values(v_uSuper,'super@t.local');
  v_uAdmin := gen_random_uuid(); insert into auth.users(id,email) values(v_uAdmin,'admin@t.local');
  v_uOpRole:= gen_random_uuid(); insert into auth.users(id,email) values(v_uOpRole,'oprole@t.local');
  v_uBO   := gen_random_uuid(); insert into auth.users(id,email) values(v_uBO,'bo@t.local');
  v_uOp   := gen_random_uuid(); insert into auth.users(id,email) values(v_uOp,'op@t.local');
  v_uBU   := gen_random_uuid(); insert into auth.users(id,email) values(v_uBU,'bu@t.local');
  v_uDrv  := gen_random_uuid(); insert into auth.users(id,email) values(v_uDrv,'drv@t.local');
  v_uOther:= gen_random_uuid(); insert into auth.users(id,email) values(v_uOther,'other@t.local');
  v_uExp  := gen_random_uuid(); insert into auth.users(id,email) values(v_uExp,'exp@t.local');
  v_uTrig := gen_random_uuid();
  insert into auth.users(id,email,raw_user_meta_data)
    values(v_uTrig,'trig@t.local','{"full_name":"Trig N","phone":"999"}'::jsonb);

  -- Papéis base (service_role path: owner insere direto — simula provisionamento admin).
  insert into public.user_platform_roles(user_id,role) values(v_uSuper,'super_admin'),(v_uAdmin,'admin'),(v_uOpRole,'operator');
  insert into public.organization_memberships(user_id,organization_id,role) values(v_uBO,v_orgA,'business_owner');

  -- T2: idempotência do insert em profiles. A trigger cria o profile ao inserir
  -- auth.users (full_name=null, sem raw_user_meta_data). Um segundo insert manual
  -- com full_name='Manual' DEVE ser no-op (on conflict do nothing) -> não duplica nem
  -- sobrescreve. (Não há como criar profile ANTES de auth.users: FK profiles.id->auth.users.id.)
  v_uTrig2 := gen_random_uuid();
  insert into auth.users(id,email) values(v_uTrig2,'trig2@t.local');  -- trigger cria profile (full_name null)
  insert into public.profiles(id,full_name) values(v_uTrig2,'Manual') on conflict (id) do nothing;  -- no-op

  -- Convite expirado (inserido direto pelo owner, simulando serviço que expirou).
  insert into public.invitations(email,role_type,invited_by_user_id,status,expires_at)
    values('exp@t.local','operator',v_uAdmin,'pending',now()-interval '1 hour');

  insert into al_ids values
    ('orgA',v_orgA),('orgB',v_orgB),
    ('uSuper',v_uSuper),('uAdmin',v_uAdmin),('uOpRole',v_uOpRole),('uBO',v_uBO),
    ('uOp',v_uOp),('uBU',v_uBU),('uDrv',v_uDrv),('uOther',v_uOther),('uExp',v_uExp),
    ('uTrig',v_uTrig),('uTrig2',v_uTrig2);
end $$;

-- helper local de asserção
create or replace function pg_temp.al(t text, exp text, act text) returns void
language plpgsql as $$
begin
  insert into al_results(test,expected,actual,pass) values(t,exp,act,exp=act);
end $$;
grant all on al_ids, al_results to authenticated, anon;
grant execute on function pg_temp.al(text,text,text) to authenticated, anon;

-- Helpers de verificação SECURITY DEFINER (criados pelo owner; rodam como postgres).
-- Necessários porque authenticated NÃO tem SELECT em user_platform_roles (Modelo B:
-- mutação de papel só via RPC; leitura de papel é sensível). A verificação do teste
-- precisa inspecionar o papel aplicado, então lê via DEFINER (não via RLS do caller).
create or replace function pg_temp.role_of(p_user uuid) returns text
language sql security definer set search_path = public, pg_catalog
as $$ select coalesce(string_agg(role::text,',' order by role),'') from public.user_platform_roles where user_id=p_user $$;
create or replace function pg_temp.role_count(p_user uuid) returns int
language sql security definer set search_path = public, pg_catalog
as $$ select count(*) from public.user_platform_roles where user_id=p_user $$;
grant execute on function pg_temp.role_of(uuid), pg_temp.role_count(uuid) to authenticated;

-- ===== T1: handle_new_user criou profile para uTrig com full_name do meta =====
select pg_temp.al('T1 handle_new_user cria profile',
  'Trig N',
  (select full_name from public.profiles where id=(select v from al_ids where k='uTrig')));
select pg_temp.al('T1b handle_new_user phone do meta',
  '999',
  (select phone from public.profiles where id=(select v from al_ids where k='uTrig')));

-- ===== T2: insert idempotente em profiles (on conflict do nothing: não duplica nem sobrescreve) =====
select pg_temp.al('T2 insert idempotente 1 linha',
  '1',
  (select count(*)::text from public.profiles where id=(select v from al_ids where k='uTrig2')));
select pg_temp.al('T2b manual NAO aplicado (on conflict do nothing)',
  'true',
  (select (full_name is distinct from 'Manual')::text from public.profiles where id=(select v from al_ids where k='uTrig2')));

-- ============================ FASE 2: RPCs (authenticated) ============================
set local role authenticated;

-- ===== T3: admin cria convite operator -> ok + token =====
select set_config('request.jwt.claims', json_build_object('sub',(select v from al_ids where k='uAdmin'))::text, true);
do $$
declare r record; begin
  select * into r from public.create_invitation('op@t.local','operator');
  insert into al_results(test,expected,actual,pass) values('T3 create_invitation ok','created',r.reason, r.ok and r.reason='created');
  insert into al_ids values('inv_op', r.token);
end $$;

-- ===== T4: business_owner convida business_user para OUTRA org -> not_authorized =====
select set_config('request.jwt.claims', json_build_object('sub',(select v from al_ids where k='uBO'))::text, true);
do $$
declare r record; v_orgB uuid := (select v from al_ids where k='orgB'); begin
  select * into r from public.create_invitation('x@t.local','business_user',v_orgB);
  insert into al_results(test,expected,actual,pass) values('T4 invite outra org negado','not_authorized',r.reason, r.reason='not_authorized');
end $$;

-- ===== T5: operator tenta convidar admin -> not_authorized =====
select set_config('request.jwt.claims', json_build_object('sub',(select v from al_ids where k='uOpRole'))::text, true);
do $$
declare r record; begin
  select * into r from public.create_invitation('new@t.local','admin');
  insert into al_results(test,expected,actual,pass) values('T5 operator convida admin negado','not_authorized',r.reason, r.reason='not_authorized');
end $$;

-- ===== T6: business_user sem organization_id -> org_required =====
select set_config('request.jwt.claims', json_build_object('sub',(select v from al_ids where k='uAdmin'))::text, true);
do $$
declare r record; begin
  select * into r from public.create_invitation('x@t.local','business_user');
  insert into al_results(test,expected,actual,pass) values('T6 business_user sem org','org_required',r.reason, r.reason='org_required');
end $$;

-- Pré-cria convites adicionais (para accept/cancel): driver (admin), business_user orgA (uBO), admin (super).
select set_config('request.jwt.claims', json_build_object('sub',(select v from al_ids where k='uAdmin'))::text, true);
do $$
declare r record; begin
  select * into r from public.create_invitation('drv@t.local','driver',null,'{"full_name":"Drv Conv","phone":"555"}'::jsonb);
  insert into al_ids values('inv_drv', r.token);
end $$;
select set_config('request.jwt.claims', json_build_object('sub',(select v from al_ids where k='uBO'))::text, true);
do $$
declare r record; v_orgA uuid := (select v from al_ids where k='orgA'); begin
  select * into r from public.create_invitation('bu@t.local','business_user',v_orgA);
  insert into al_ids values('inv_bu', r.token);
end $$;
select set_config('request.jwt.claims', json_build_object('sub',(select v from al_ids where k='uSuper'))::text, true);
do $$
declare r record; begin
  select * into r from public.create_invitation('newadmin@t.local','admin');
  insert into al_ids values('inv_admin', r.token);
end $$;

-- ===== T7: uOp aceita convite operator -> accepted + role aplicada =====
select set_config('request.jwt.claims', json_build_object('sub',(select v from al_ids where k='uOp'))::text, true);
do $$
declare r record; v_uOp uuid := (select v from al_ids where k='uOp'); begin
  select * into r from public.accept_invitation((select v from al_ids where k='inv_op'));
  insert into al_results(test,expected,actual,pass) values('T7 accept ok','accepted',r.reason, r.ok and r.reason='accepted');
  insert into al_results(test,expected,actual,pass) values('T7b role aplicado','operator',
    pg_temp.role_of(v_uOp),
    pg_temp.role_of(v_uOp)='operator');
  insert into al_results(test,expected,actual,pass) values('T7c status accepted','accepted',
    (select status::text from public.invitations where token=(select v from al_ids where k='inv_op')),
    (select status='accepted' from public.invitations where token=(select v from al_ids where k='inv_op')));
end $$;

-- ===== T8: aceitar de novo (idempotência) -> already_accepted, 1 role =====
do $$
declare r record; v_uOp uuid := (select v from al_ids where k='uOp'); begin
  select * into r from public.accept_invitation((select v from al_ids where k='inv_op'));
  insert into al_results(test,expected,actual,pass) values('T8 accept 2x already_accepted','already_accepted',r.reason, r.reason='already_accepted');
  insert into al_results(test,expected,actual,pass) values('T8b 1 role apenas','1',
    pg_temp.role_count(v_uOp)::text,
    pg_temp.role_count(v_uOp)=1);
end $$;

-- ===== T9: email divergente (uOther aceita inv_op) -> not_authorized =====
select set_config('request.jwt.claims', json_build_object('sub',(select v from al_ids where k='uOther'))::text, true);
do $$
declare r record; begin
  select * into r from public.accept_invitation((select v from al_ids where k='inv_op'));
  insert into al_results(test,expected,actual,pass) values('T9 email divergente negado','not_authorized',r.reason, r.reason='not_authorized');
end $$;

-- ===== T10: convite expirado -> expired (status vira expired) =====
select set_config('request.jwt.claims', json_build_object('sub',(select v from al_ids where k='uExp'))::text, true);
do $$
declare r record; v_uExp uuid := (select v from al_ids where k='uExp'); begin
  select * into r from public.accept_invitation((select token from public.invitations where email='exp@t.local' and invited_by_user_id=(select v from al_ids where k='uAdmin')));
  insert into al_results(test,expected,actual,pass) values('T10 expirado negado','expired',r.reason, r.reason='expired');
  insert into al_results(test,expected,actual,pass) values('T10b status virou expired','expired',
    (select status::text from public.invitations where email='exp@t.local'),
    (select status='expired' from public.invitations where email='exp@t.local'));
end $$;

-- ===== T12: uDrv aceita convite driver -> drivers row criada (pending) =====
select set_config('request.jwt.claims', json_build_object('sub',(select v from al_ids where k='uDrv'))::text, true);
do $$
declare r record; v_uDrv uuid := (select v from al_ids where k='uDrv'); begin
  select * into r from public.accept_invitation((select v from al_ids where k='inv_drv'));
  insert into al_results(test,expected,actual,pass) values('T12 accept driver ok','accepted',r.reason, r.ok and r.reason='accepted');
  insert into al_results(test,expected,actual,pass) values('T12b driver row criada','1',
    (select count(*)::text from public.drivers where user_id=v_uDrv),
    exists(select 1 from public.drivers where user_id=v_uDrv and account_status='pending' and full_name='Drv Conv'));
end $$;

-- ===== T13: admin cancela convite admin pending -> cancelled; cancelar accepted -> not_pending =====
select set_config('request.jwt.claims', json_build_object('sub',(select v from al_ids where k='uAdmin'))::text, true);
do $$
declare r record; v_invAdmin uuid; begin
  select id into v_invAdmin from public.invitations where token=(select v from al_ids where k='inv_admin');
  select * into r from public.cancel_invitation(v_invAdmin);
  insert into al_results(test,expected,actual,pass) values('T13 cancel pending ok','cancelled',r.reason, r.ok and r.reason='cancelled');
  -- cancelar convite já accepted (inv_op) -> not_pending
  select * into r from public.cancel_invitation((select id from public.invitations where token=(select v from al_ids where k='inv_op')));
  insert into al_results(test,expected,actual,pass) values('T13b cancel accepted negado','not_pending',r.reason, r.reason='not_pending');
end $$;

-- ===== T14: admin atribui operator a uBU (idempotente) =====
do $$
declare r record; v_uBU uuid := (select v from al_ids where k='uBU'); begin
  select * into r from public.assign_platform_role(v_uBU,'operator');
  insert into al_results(test,expected,actual,pass) values('T14 assign_platform_role ok','assigned',r.reason, r.ok and r.reason='assigned');
  -- 2a chamada idempotente
  select * into r from public.assign_platform_role(v_uBU,'operator');
  insert into al_results(test,expected,actual,pass) values('T14b assign idempotente','assigned',r.reason, r.ok);
  insert into al_results(test,expected,actual,pass) values('T14c 1 role','1',
    pg_temp.role_count(v_uBU)::text,
    pg_temp.role_count(v_uBU)=1);
end $$;

-- ===== T15: não-admin (uBU) tenta assign_platform_role -> not_authorized =====
select set_config('request.jwt.claims', json_build_object('sub',(select v from al_ids where k='uBU'))::text, true);
do $$
declare r record; v_uOther uuid := (select v from al_ids where k='uOther'); begin
  select * into r from public.assign_platform_role(v_uOther,'operator');
  insert into al_results(test,expected,actual,pass) values('T15 nao-admin assign negado','not_authorized',r.reason, r.reason='not_authorized');
end $$;

-- ===== T16: business_owner adiciona business_user à própria org; outra org -> negado =====
-- uBU já tem platform role operator (T14), mas NÃO é business_owner. Usa uBO (owner de orgA).
select set_config('request.jwt.claims', json_build_object('sub',(select v from al_ids where k='uBO'))::text, true);
do $$
declare r record; v_orgA uuid := (select v from al_ids where k='orgA'); v_orgB uuid := (select v from al_ids where k='orgB'); v_uOther uuid := (select v from al_ids where k='uOther'); begin
  select * into r from public.add_org_member(v_uOther,v_orgA,'business_user');
  insert into al_results(test,expected,actual,pass) values('T16 add_org_member propria org','added',r.reason, r.ok and r.reason='added');
  select * into r from public.add_org_member(v_uOther,v_orgB,'business_user');
  insert into al_results(test,expected,actual,pass) values('T16b add_org_member outra org negado','not_authorized',r.reason, r.reason='not_authorized');
end $$;

-- ===== T17: admin provisiona driver via create_driver -> created =====
select set_config('request.jwt.claims', json_build_object('sub',(select v from al_ids where k='uAdmin'))::text, true);
do $$
declare r record; v_uOther uuid := (select v from al_ids where k='uOther'); begin
  select * into r from public.create_driver(v_uOther,'Outro Drv','777');
  insert into al_results(test,expected,actual,pass) values('T17 create_driver ok','created',r.reason, r.ok and r.reason='created' and r.driver_id is not null);
  -- idempotente: 2a chamada -> already_exists
  select * into r from public.create_driver(v_uOther,'Outro Drv','777');
  insert into al_results(test,expected,actual,pass) values('T17b create_driver idempotente','already_exists',r.reason, r.ok);
end $$;

-- ===== T18: RLS de invitations — visibilidade =====
-- convidado PURO (uExp, sem papel platform) vê só seu convite (exp@t.local, 1).
-- (uOp é operator -> is_platform_admin true -> vê todos; não serve para isolar o
--  branch "convidado vê o seu". uExp nunca recebeu papel: o accept em T10 foi negado
--  por expiração.)
select set_config('request.jwt.claims', json_build_object('sub',(select v from al_ids where k='uExp'))::text, true);
select pg_temp.al('T18 convidado puro vê só seu convite','1',
  (select count(*)::text from public.invitations));

-- inviter NÃO-admin (uBO, business_owner) vê só o que criou (inv_bu) = 1.
-- (uAdmin é platform admin -> is_platform_admin() true -> vê todos; testado em T18d.)
select set_config('request.jwt.claims', json_build_object('sub',(select v from al_ids where k='uBO'))::text, true);
select pg_temp.al('T18b inviter nao-admin vê só o que criou','1',
  (select count(*)::text from public.invitations));

-- platform admin (uAdmin) vê TODOS os convites (5: inv_op, inv_drv, inv_admin, inv_bu, exp@).
select set_config('request.jwt.claims', json_build_object('sub',(select v from al_ids where k='uAdmin'))::text, true);
select pg_temp.al('T18d platform admin vê todos','5',
  (select count(*)::text from public.invitations));

-- user alheio (uOther) não é inviter nem convidado de nenhum pending visível -> 0
select set_config('request.jwt.claims', json_build_object('sub',(select v from al_ids where k='uOther'))::text, true);
select pg_temp.al('T18c alheio vê 0','0',
  (select count(*)::text from public.invitations));

-- ===== T19: anon bloqueado (sem SELECT em invitations, sem EXECUTE em accept_invitation) =====
-- Por design (ADR-010 D3): anon NÃO recebe grants em invitations nem EXECUTE em
-- accept_invitation. Logo é bloqueado no nível de privilégio (exceção 42501), defesa
-- em profundidade ANTES do checagem interna de auth.uid(). Verificamos a exceção.
set local role anon;
do $$
declare r record; v_blocked boolean := false; v_blocked2 boolean := false; begin
  begin
    perform count(*) from public.invitations;   -- anon sem SELECT -> 42501
  exception when others then v_blocked := true; end;
  insert into al_results(test,expected,actual,pass)
    values('T19 anon sem SELECT em invitations','true',v_blocked::text, v_blocked);
  begin
    select * into r from public.accept_invitation(gen_random_uuid());  -- anon sem EXECUTE -> 42501
  exception when others then v_blocked2 := true; end;
  insert into al_results(test,expected,actual,pass)
    values('T19b anon sem EXECUTE em accept_invitation','true',v_blocked2::text, v_blocked2);
end $$;

-- ===== RESULTADO FINAL (único resultset consolidado) =====
select
  count(*) as total,
  sum((pass)::int) as passed,
  count(*) filter (where not pass) as failed,
  (select string_agg(test||' ['||expected||'/'||actual||']', ' | ' order by test)
   from al_results where not pass) as failures,
  (select string_agg(test||'=OK', ' | ' order by test)
   from al_results where pass) as passing
from al_results;

rollback;