-- 0003_helpers.sql
-- Função CENTRAL de updated_at. Uma única função, reaproveitada por todos os
-- triggers (nunca duplicar cópias por tabela). Ver ADR / convenção em BACKEND.md.

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_catalog
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

comment on function public.set_updated_at() is
  'Função central de updated_at. Cada tabela cria seu trigger apontando para esta única função.';