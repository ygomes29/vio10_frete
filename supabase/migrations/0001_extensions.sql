-- 0001_extensions.sql
-- Extensões necessárias: pgcrypto (uuids) e PostGIS (geoespacial).
-- ADR-005: PostGIS para pré-filtro de candidatos; Google Maps entra depois para rota/ETA.
--
-- PostGIS fica em schema dedicado `extensions` (recomendação Supabase), NÃO em public,
-- para não poluir public com geography/geometry/ST_*/spatial_ref_sys. O schema `extensions`
-- já está no search_path padrão do Supabase ("$user", public, extensions), então referências
-- não-qualificadas (geography, geometry, ST_DWithin, ST_MakePoint, ...) resolvem normalmente.

create extension if not exists "pgcrypto";
create extension if not exists "postgis" with schema extensions;

comment on extension "postgis" is
  'ViO10: usado para pré-filtragem geoespacial de entregadores e áreas de serviço. NÃO substitui o routing provider (Google Maps). Instalado no schema extensions.';