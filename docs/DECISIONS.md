# docs/DECISIONS.md — Log consolidado de decisões

> Decisões arquiteturais formais. Cada uma tem um ADR correspondente em
> `docs/adr/`. Este arquivo é o índice legível; os ADRs são o registro detalhado.

## Status

Aprovadas na Sessão 02 (2026-08-27).

## Índice de ADRs

| ADR | Decisão | Status |
|---|---|---|
| ADR-001 | Banco (Postgres/Supabase) como fonte da verdade | Aprovado |
| ADR-002 | Backend dentro do Next.js no MVP (Route Handlers + serviços + RPC) | Aprovado |
| ADR-003 | Supabase como plataforma de dados/auth/storage/realtime | Aprovado |
| ADR-004 | n8n somente como orquestrador (não fonte da verdade) | Aprovado |
| ADR-005 | Google Maps atrás de provider abstraction (TWO_WHEELER) | Aprovado |
| ADR-006 | bidding round antes da atribuição (ACEITAR ≠ GANHAR) | Aprovado |
| ADR-007 | Atribuição atomicamente protegida pelo banco | Aprovado |
| ADR-008 | Valores financeiros em centavos inteiros | Aprovado |

## Decisões adicionais registradas (sem ADR próprio, mas vinculadas)

- **Tenancy**: `organization → business → business_location`.
- **Estados da corrida**: `bidding` não é estado principal; disputa dentro de
  `searching_driver`.
- **Localização do entregador**: ~10s em foreground; conceito de `stale`; app
  nativo só se justificar.
- **Frontend**: 3 superfícies em 1 codebase Next.js (route groups); nunca inventa
  estado.
- **Server Actions**: só para ações originadas no frontend; n8n/DataCrazy não
  dependem delas.
- **Idempotência**: `idempotency_key` + `external_event_id`; retries são normais.
- **Observabilidade**: `correlation_id` + contexto por evento crítico.
- **Next.js**: 16.3.3 Active LTS (não 15); confirmar patch mais recente ao inicializar.

## Decisões adicionais da Sessão 03.5 (validação, 2026-08-28)

- **PostGIS em schema `extensions`**: `geography`/`ST_*` ficam em `extensions` (não em
  `public`), para não poluir `public`. Migrations que usam PostGIS declaram
  `set search_path to public, extensions;` (o runner de migrations/testes não inclui
  `extensions` no search_path padrão).
- **Grants default-deny total (0014)**: além de RLS default-deny, revoga-se
  explicitamente de `anon`/`authenticated`/`service_role` (existentes + `ALTER
  DEFAULT PRIVILEGES FOR ROLE postgres`) porque o Supabase auto-concede a esses roles
  via default privileges. Grants finais (least-privilege por função/tabela) na Sessão 04.
- **R16 — perdedoras cross-round**: após a atribuição oficial, TODAS as offers ainda
  respondíveis da corrida inteira (em qualquer rodada) viram `lost` — `claim_delivery`
  filtra por `delivery_request_id`, não por rodada. Escopo é a corrida, não a rodada.
- **R17 — `external_reference` ≠ `idempotency_key`**: conceitos distintos (vínculo
  externo vs retry de operação); ver `docs/SECURITY.md`.
- **`service_role` user-scoped vs system-scoped**: operações de usuário rodam
  user-scoped (`authenticated`, RLS aplica); operações do sistema rodam system-scoped
  (`service_role`, bypass). `service_role` nunca vaza para integradores externos;
  RPCs são `SECURITY INVOKER`. Ver `ARCHITECTURE.md` §3.1.
- **pgTAP server-side sem Docker**: runner próprio (temp table `_tap` + `num_failed()`
  + `begin/rollback` clean-slate) para executar testes via Management API quando Docker
  está ausente.

## Decisões ainda em aberto (a resolver nas próximas sessões)

- Hospedagem final do n8n (self-host confirmado; infra específica na Sessão 13).
- Detalhes do modelo financeiro (Sessão 21 — desenhar antes de implementar).
- Limites concretos do piloto (Sessão 26).
- Provider geocoder secundário (Nominatim/Mapbox) se custo do Google justificar
  (Sessão 20).

## Como propor nova decisão

Toda decisão arquitetural relevante vira um novo ADR em `docs/adr/` (número
sequencial) e é listada aqui. Não decidir arquitetura em conversa sem registro.