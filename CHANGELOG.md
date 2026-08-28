# CHANGELOG.md — Histórico do ViO10

Formato: sessão + data + escopo.

## [Sessão 02] — 2026-08-27 — Fundação documental

### Adicionado
- Documentação raiz: `CLAUDE.md`, `ARCHITECTURE.md`, `BACKEND.md`, `FRONTEND.md`,
  `PLAN.md`, `CODE_REVIEW.md`, `CHANGELOG.md`.
- Documentação em `/docs`: `PRODUCT.md`, `DELIVERY_LIFECYCLE.md`,
  `DISPATCH_ENGINE.md`, `BID_ENGINE.md`, `PRICING_ENGINE.md`, `N8N_WORKFLOWS.md`,
  `DATACRAZY_INTEGRATION.md`, `SECURITY.md`, `GEOLOCATION.md`, `DECISIONS.md`.
- ADRs: `ADR-001` a `ADR-008` em `docs/adr/`.

### Decisões formalizadas
- Stack: Next.js 16.3.3 (Active LTS), Supabase, n8n self-hosted, DataCrazy, Google
  Maps Platform.
- Backend dentro do Next.js (Route Handlers para externos; Server Actions só para
  frontend); atomicidade via RPC do Postgres.
- Tenancy `organization → business → business_location`.
- Dinheiro em centavos inteiros.
- `bidding` não é estado principal (sub-fase de `searching_driver`).
- **Correção crítica**: ACEITAR = lance igual ao valor ofertado (não vitória
  imediata); rodada coleta candidatos, fecha, pontua, e só então `claim_delivery()`
  atômico.
- Google Maps atrás de abstração de provider (TWO_WHEELER para motos no Brasil).
- Localização do entregador: ~10s em foreground; conceito de `stale`.
- Idempotência formalizada (`idempotency_key`, `external_event_id`).
- Observabilidade: correlation_id + contexto por evento crítico.

### Inconsistências da Sessão 01 corrigidas
- Semântica de ACEITAR/ganho imediato → rejeitada e substituída pelo modelo de
  rodada com janela + scoring + claim atômico (ADR-006).
- OSRM self-hosted como dependência inicial → substituído por Google Maps atrás de
  abstração (ADR-005).
- Next.js 15 → Next.js 16.3.3 Active LTS.
- n8n/DataCrazy dependentes de Server Actions → proibido; usam Route Handlers.

## [Sessão 03] — 2026-08-27 — Fundação do banco de dados

### Adicionado
- `supabase/` scaffoldado (`supabase init`): `config.toml`, `migrations/`, `tests/`.
- 13 migrations: `0001_extensions` (postgis+pgcrypto), `0002_enums`, `0003_helpers`
  (função central `set_updated_at`), `0004_identity_tenancy`, `0005_drivers`,
  `0006_service_areas`, `0007_delivery_core`, `0008_pricing`, `0009_dispatch_bids`,
  `0010_assignments_events`, `0011_integrations_notifications_pod`, `0012_rls`,
  `0013_rpcs`.
- Tabelas: organizations, businesses, business_locations, profiles,
  user_platform_roles, organization_memberships, drivers, vehicles,
  driver_documents, driver_availability, driver_locations, service_areas,
  delivery_requests, delivery_items, pricing_rules, delivery_quotes,
  dispatch_rounds, delivery_offers, bids, delivery_assignments, delivery_events,
  webhook_events, integration_events, notifications, proof_of_delivery.
- RPCs atômicos: `claim_delivery` (atribuição atômica, FOR UPDATE + partial unique),
  `respond_to_offer` (idempotente, não atribui), `transition_delivery` (matriz de
  estados + supersede em reatribuição), `set_driver_availability` (estado + log).
- PostGIS: `geography(Point,4326)` em driver_locations, service_areas,
  business_locations, delivery_requests (pickup/delivery), proof_of_delivery;
  índices GiST.
- Invariante crítica protegida no banco: `UNIQUE(delivery_request_id) WHERE
  status='active'` em `delivery_assignments`.
- FK composto `bids(delivery_offer_id, driver_id) → delivery_offers(id, driver_id)`
  garante bid coerente com offer/driver.
- Imutabilidade de `delivery_events` via trigger (bloqueia update/delete).
- RLS habilitado em todas as tabelas, **default deny** (sem policies amplas).
- Suíte pgTAP (`supabase/tests/test_vio10_invariants.sql`) cobrindo 11 invariantes.

### Decisões de modelagem
- Dinheiro: `BIGINT` `*_cents`, currency BRL (overflow-safe para ledger futuro).
- Disponibilidade: `drivers.current_availability_status` (filtro) + `driver_availability`
  log append-only (auditoria), atualizados juntos.
- Snapshots: `delivery_requests` snapshot de coleta/entrega; `delivery_quotes` e
  `dispatch_rounds` snapshotam config/valores.
- Tenancy duplo escopo: papéis platform-scoped (`user_platform_roles`) e org-scoped
  (`organization_memberships`); drivers são platform-scoped (sem organization_id).
- Financeiro adiado à Sessão 21 (sem dependências de FK atuais).

### Limitação
- Testes **não executados** neste ambiente (Docker ausente). `supabase start`/
  `supabase db test` requerem Docker. Suíte pronta para execução quando disponível.

## [Sessão 03.5] — 2026-08-27 — Validação real da fundação do banco (Gate B)

> Executada contra projeto Supabase **dev** (`rtoyfiqngyicqtuzwfhz`). Nunca em produção.
> Resultado: **PASS** (ver `CODE_REVIEW.md` e veredito GO ao final).

### Executado (real, não simulado)
- **Reset completo + cadeia 0001→0014 reproduzida do zero** num único pass: 25 tabelas,
  16 enums, 7 funções, 25 tabelas com RLS, 14 migrations. Banco nasce do zero.
- **pgTAP executado server-side** (sem Docker; runner próprio com temp table + rollback
  clean-slate via `supabase db query --linked`/Management API): **12/12 invariantes
  PASS** (`test_vio10_invariants.sql`).
- **RPCs executadas**: **48/48 PASS** (`test_vio10_rpcs.sql` — 4 RPCs × cenários
  cobrindo happy path, expiração, idempotência, transições inválidas, FK, reatribuição).
- **Concorrência `claim_delivery`**: 2 claims contra a mesma delivery
  (`searching_driver`, 2 offers aceitas). Resultado: **exatamente 1 `won=true`**
  (B), o outro `won=false` (`not_searching_driver`). Estado final: 1 assignment ativa,
  1 offer `won`, 1 offer `lost`. Nunca A=true E B=true. Garantia física: partial unique
  index `idx_delivery_assignments_active_uk` + `SELECT … FOR UPDATE`.
- **`delivery_events` imutável**: trigger `enforce_delivery_events_immutable` bloqueia
  UPDATE/DELETE (T12 PASS).
- **RLS default deny**: role com `SELECT` concedido e sem policy vê 0 linhas (T10 PASS).
- **Grants audit**: após 0014, `anon`/`authenticated`/`service_role` com **0**
  privilégios (EXECUTE/DML) em 25 tabelas + 10 funções; `postgres` (owner) retém.

### Correções aplicadas
- **PostGIS no search_path**: migrations 0004/0005/0006/0007/0011 + test files recebem
  `set search_path to public, extensions;` (o runner não inclui `extensions` no
  search_path padrão; `geography`/`ST_*` vivem em `extensions`). Sem isto: `42704`.
- **0014 endurecido (gap de segurança real)**: o `revoke … from public` não removia
  os auto-grants do Supabase (`ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA
  public` concede `arwdDxtm`/`X`/`rwU` a `anon`/`authenticated`/`service_role`
  diretamente). 0014 agora revoga de `public, anon, authenticated, service_role`
  (existentes) + `ALTER DEFAULT PRIVILEGES … REVOKE` (futuros). Default-deny total.
- **R16 corrigido/verificado**: após atribuição oficial, TODAS as offers ainda
  respondíveis da **corrida inteira** (em qualquer rodada, não só da vencedora) viram
  `lost`. `claim_delivery` filtra por `delivery_request_id`, não por rodada. Teste
  cross-round real: offer aceita em rodada anterior marcada `lost` após claim pela
  rodada 2. Resolve o risco MÉDIO da Sessão 03.
- **R17 documentado**: `external_reference` ≠ `idempotency_key` (conceitos distintos;
  ver `docs/SECURITY.md`, `BACKEND.md` §5, `0007`). Resolve o risco BAIXO da Sessão 03.
- **Correção arquitetural `service_role`**: distingue user-scoped (`authenticated`,
  RLS aplica) vs system-scoped (`service_role`, bypass); `service_role` nunca vaza
  para n8n/DataCrazy/IA; RPCs `SECURITY INVOKER`. Ver `ARCHITECTURE.md` §3.1,
  `BACKEND.md` §6, `docs/SECURITY.md`.
- pgTAP `throws_ok` 3-arg → 4-arg (SQLSTATE como `char(5)` + `null` errmsg) para não
  tratar a descrição como mensagem esperada.
- Runner pgTAP server-side (`/tmp/vio10_gen_runner.sh`): captura TAP em temp table +
  `num_failed()` veredito + `begin/rollback` clean-slate.

### Não implementado (fora de escopo, conforme prompt)
- Auth/RBAC, grants finais (least-privilege por função), policies RLS → **Sessão 04**.
- `select_winner_and_claim` (scoring/atribuição automática) → Sessão 09/10.
- Frontend, workflows n8n, integração DataCrazy → sessões futuras.

## [Sessão 01] — 2026-08-27 — Diagnóstico
- Repositório confirmado greenfield.
- Arquitetura proposta e aprovada com ajustes (ver Sessão 02).