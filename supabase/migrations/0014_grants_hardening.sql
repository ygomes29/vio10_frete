-- 0014_grants_hardening.sql
-- Endurecimento de privilégios: default deny no nível de GRANTS (RLS já é default deny).
--
-- Postgres concede EXECUTE em funções a PUBLIC por padrão. Além disso, o Supabase
-- instala ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public que concede
-- TODAS as privileges (arwdDxtm em tabelas, X em funções, rwU em sequences) a
-- anon, authenticated E service_role automaticamente em todo objeto criado em public.
-- Sem revogar explicitamente desses três roles, anon/authenticated poderiam INVOCAR
-- claim_delivery / respond_to_offer / transition_delivery e SELECT/INSERT em qualquer
-- tabela diretamente via PostgREST, mesmo com RLS default-deny nas tabelas (a chamada
-- entraria na função; a segurança real ficaria só na RLS interna, não no grant).
--
-- A postura do ViO10 é default deny total: nenhuma exposição inesperada. Os grants/
-- policies finais (anon, authenticated, service_role por função/tabela) ficam para
-- a Sessão 04. Até lá, NENHUM dos três roles tem qualquer privilégio em public.
--
-- OBSERVAÇÕES:
-- * O OWNER (postgres) retém todos os privilégios — migrations e testes (que rodam como
--   postgres) continuam funcionando.
-- * Triggers chamam funções (set_updated_at, enforce_delivery_events_immutable) no contexto
--   do dono da tabela — continuam funcionando (owner tem EXECUTE).
-- * service_role/anon/authenticated ficam SEM EXECUTE/SELECT/INSERT/... até a Sessão 04.
-- * ALTER DEFAULT PRIVILEGES garante que migrations FUTURAS (Sessão 04 em diante) também
--   não auto-concedam a anon/authenticated/service_role — todo grant futuro é explícito.

-- 1) Revoga grants EXISTENTES (tabelas/funções/sequences já criadas em public) de todos
--    os roles não-owner: PUBLIC, anon, authenticated, service_role.
revoke all on all functions in schema public from public, anon, authenticated, service_role;
revoke all on all tables    in schema public from public, anon, authenticated, service_role;
revoke all on all sequences in schema public from public, anon, authenticated, service_role;

-- 2) Revoga DEFAULT PRIVILEGES concedidos pelo Supabase (grantor postgres) em public,
--    para que objetos criados por migrations futuras também nasçam SEM auto-grant a
--    anon/authenticated/service_role. Sessão 04 concederá explicitamente o necessário.
alter default privileges for role postgres in schema public
  revoke all on tables    from anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  revoke all on functions from anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  revoke all on sequences from anon, authenticated, service_role;

-- Registra a postura explicitamente.
comment on schema public is
  'ViO10: schema de domínio. RLS + grants em default deny total desde a Sessão 03.5; grants/policies finais (least-privilege por função/tabela) na Sessão 04.';