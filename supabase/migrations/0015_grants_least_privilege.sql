-- 0015_grants_least_privilege.sql
-- Grants least-privilege (substitui o default-deny total do 0014 por acesso explícito).
-- Especificação: ADR-009 (matriz papel × recurso × ação — escopo MVP).
--
-- Modelo B (decidido na Sessão 04; ver ARCHITECTURE.md §3.1 e ADR-009):
-- * service_role = system-scoped, bypassa RLS (rolbypassrls). Backend confiável. DML
--   direto em todas as tabelas + EXECUTE nas 4 RPCs.
-- * authenticated = user-scoped para LEITURA (SELECT sob RLS — 0017 define policies) +
--   EXECUTE nas RPCs user-facing. As RPCs user-facing são SECURITY DEFINER (0016) com
--   checagem de auth.uid() interna: rodam como owner, validam posse, e NÃO expõem
--   DML direto às tabelas. Assim um entregador logado NÃO pode bypassar a máquina de
--   estados via PostgREST direto (não tem grant de UPDATE em delivery_requests).
-- * anon = nada (MVP sem superfície pública).
--
-- Exceção ao "sem DML ao authenticated": driver_locations (telemetria de posição,
-- sem regra de negócio a bypassar) — INSERT/UPDATE diretos sob RLS (driver_id = self).
--
-- 0014 manteve ALTER DEFAULT PRIVILEGES FOR ROLE postgres REVOKE em public — objetos
-- criados por migrations futuras continuam a nascer sem auto-grant; todo acesso futuro
-- é explícito (least-privilege).

-- =========================================================================
-- service_role (system-scoped, bypass RLS): o backend de sistema.
-- EXECUTE nas 4 RPCs + DML (select/insert/update/delete) em todas as tabelas de
-- domínio. É a role confiável (chave nunca vaza para n8n/DataCrazy/IA). service_role
-- não recebe TRUNCATE/REFERENCES/TRIGGER (desnecessários).
-- =========================================================================
grant execute on function public.claim_delivery(uuid,uuid,uuid,uuid,uuid,uuid)        to service_role;
grant execute on function public.respond_to_offer(uuid,uuid,bid_response_type,bigint,text,uuid) to service_role;
grant execute on function public.transition_delivery(uuid,delivery_status,text,uuid,jsonb,uuid) to service_role;
grant execute on function public.set_driver_availability(uuid,driver_availability_status,text) to service_role;

grant select, insert, update, delete on all tables in schema public to service_role;

-- =========================================================================
-- authenticated (user-scoped): motorista, business, admin, operator.
-- EXECUTE nas RPCs user-facing (SECURITY DEFINER com check de auth.uid() em 0016).
-- NÃO recebe DML direto em tabelas de domínio (evita bypass da máquina de estados via
-- PostgREST). A única mutação direta permitida é driver_locations (telemetria).
-- =========================================================================
grant execute on function public.respond_to_offer(uuid,uuid,bid_response_type,bigint,text,uuid) to authenticated;
grant execute on function public.transition_delivery(uuid,delivery_status,text,uuid,jsonb,uuid) to authenticated;
grant execute on function public.set_driver_availability(uuid,driver_availability_status,text) to authenticated;
-- claim_delivery: NÃO concedido a authenticated (atribuição = system/operator via backend).

-- SELECT: tabelas de domínio visíveis ao usuário (RLS em 0017 filtra por org/driver).
grant select on
  public.organizations,
  public.businesses,
  public.business_locations,
  public.drivers,
  public.driver_locations,
  public.driver_availability,
  public.driver_documents,
  public.vehicles,
  public.delivery_requests,
  public.delivery_items,
  public.delivery_quotes,
  public.dispatch_rounds,
  public.delivery_offers,
  public.bids,
  public.delivery_assignments,
  public.delivery_events,
  public.proof_of_delivery,
  public.notifications,
  public.pricing_rules,
  public.service_areas
  to authenticated;
-- NÃO concedido a authenticated: webhook_events, integration_events (sistema),
-- user_platform_roles, organization_memberships (metadados de authz; backend
-- resolve server-side), profiles (auth usa auth.users; perfil via backend).

-- driver_locations: telemetria de posição (sem regra de negócio a bypassar). O entregador
-- grava/refresca apenas a PRÓPRIA posição; RLS (0017) garante driver_id = self.
grant insert, update on public.driver_locations to authenticated;

-- DELETE: nenhum para authenticated no MVP.

-- =========================================================================
-- anon: nada. MVP não tem superfície pública. (0014 já revogou; reafirmado: nenhum grant.)
-- =========================================================================

-- Sequências: tabelas usam uuid default gen_random_uuid() — sem sequences de domínio.
-- (Nenhuma grant de sequence necessária.)

-- =========================================================================
-- Registra a postura.
-- =========================================================================
comment on schema public is
  'ViO10: schema de domínio. Grants least-privilege (Sessão 04 / 0015, ADR-009, Modelo B): service_role system-scoped + authenticated user-scoped (SELECT sob RLS + EXECUTE em RPCs DEFINER com check de auth.uid()); anon sem acesso. Mutação user-facing só via RPC (sem DML direto). RLS policies em 0017.';