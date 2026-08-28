-- 0012_rls.sql
-- RLS HABILITADO desde o primeiro dia com DEFAULT DENY.
-- Nenhuma policy permissiva ampla (ex.: "authenticated can do everything").
-- O backend usa service role (bypassa RLS). Políticas completas ficam para a Sessão 04.
-- Testes de banco rodam em contexto service role / local SQL.

do $$
declare
  t text;
  tables text[] := array[
    'profiles','organizations','businesses','business_locations',
    'user_platform_roles','organization_memberships',
    'drivers','vehicles','driver_documents','driver_availability','driver_locations',
    'service_areas',
    'delivery_requests','delivery_items',
    'pricing_rules','delivery_quotes',
    'dispatch_rounds','delivery_offers','bids',
    'delivery_assignments','delivery_events',
    'webhook_events','integration_events','notifications','proof_of_delivery'
  ];
begin
  foreach t in array tables loop
    execute format('alter table public.%I enable row level security;', t);
    execute format('comment on table public.%I is %L;',
      t, 'RLS habilitado, default deny. Policies completas na Sessão 04. Backend usa service role.');
  end loop;
end $$;