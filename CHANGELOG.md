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
- `select_winner_and_claim` (scoring/atribuição automática) → Sessão 09/10.
- Frontend, workflows n8n, integração DataCrazy → sessões futuras.

## [Sessão 04] — 2026-08-28 — Auth/Grants/RLS/RBAC (Modelo B)

### Decidido
- **ADR-009**: matriz RBAC (6 papéis × recursos × ações) — spec fixa antes de
  grants/policies, para não inventar permissões. Papéis: `super_admin`/`admin`/
  `operator` (platform-scoped em `user_platform_roles`), `driver` (platform-scoped,
  identificado por linha em `drivers` — **não** em `user_platform_roles`), e
  `business_owner`/`business_user` (org-scoped em `organization_memberships`).
- **Modelo B** (decisão de usuário via AskUserQuestion): RPCs user-facing viram
  `SECURITY DEFINER` + checagem interna de `auth.uid()`. **Reverte** a decisão
  INVOKER da Sessão 03. Motivo: INVOKER exigiria grants de DML a `authenticated`,
  abrindo bypass da máquina de estados via PostgREST direto (PATCH em
  `delivery_requests.status`). DEFINER + sem DML de domínio ao `authenticated` fecha
  o buraco; `auth.uid()` funciona sob DEFINER (lê o JWT, não o role do DB).

### Adicionado
- `supabase/migrations/0016_rpcs_security_definer.sql`: recria as 4 RPCs
  (`claim_delivery`, `respond_to_offer`, `transition_delivery`,
  `set_driver_availability`) como `SECURITY DEFINER` com checagem `auth.uid()`:
  `null` → system (service_role/owner), permitido; não-null → user, valida
  `drivers.user_id = auth.uid()` (motorista), membership da org (business) ou
  `user_platform_roles` (admin/operator). `transition_delivery` deriva o actor de
  `auth.uid()` (não confia nos params). Revoga grants PUBLIC, reaplica EXECUTE
  conforme 0015.
- `supabase/migrations/0017_rls_policies.sql`: RLS policies de visibilidade (o "V"
  da matriz ADR-009) + 5 helpers `SECURITY DEFINER` (`is_platform_admin`,
  `my_driver_id`, `my_org_ids`, `is_org_member`, `can_view_delivery_request`).
  Isolamento: business_* por `organization_id`; driver por offers/assignments
  dirigidas a ele; platform admin vê tudo; user sem papel/membership/driver vê 0
  (default-deny). Mutação direta do `authenticated` só em `driver_locations`
  (telemetria, `driver_id = self`).
- `supabase/tests/test_vio10_authz.sql`: 21 asserções de autorização (cross-tenant,
  isolamento de driver, papel sem policy vê 0, admin cross-tenant, bypass UPDATE
  bloqueado, `respond_to_offer` bloqueia driver errado, caminho legítimo ok).

### Validado (real, no projeto dev `rtoyfiqngyicqtuzwfhz`, via Management API)
- 0016 aplicada; 4 RPCs confirmadas `SECURITY DEFINER`.
- 0017 aplicada; inventário final: 26 tabelas com RLS, 25 policies, 4 RPCs DEFINER,
  5 helpers, `authenticated` SELECT=20 / INSERT=1 / UPDATE=1 / EXECUTE=8, `anon`=0.
- `test_vio10_authz.sql`: **21/21 PASS**.
- Caminho system (auth.uid null): smoke `claim_delivery` **4/4** (won, reason=won,
  offer perdedora lost, delivery assigned).
- R16 cross-round: **PASS** (offer aceita em rodada anterior vira lost após
  atribuição oficial por outra rodada) — preservado sob DEFINER.
- Concorrência: A e B em paralelo → **exatamente um** `won=true` (B), outro
  `not_searching_driver`; nunca ambos. Partial unique index + FOR UPDATE intactos
  sob DEFINER.
- Bypass da máquina de estados via PostgREST direto: **FECHADO** (UPDATE em
  `delivery_requests` por `authenticated` → `insufficient_privilege`).

### Documentação
- `docs/adr/ADR-009-matriz-rbac.md`: matriz + mapeamento (0016=RPCs DEFINER,
  0017=RLS, 0015=grants).
- `ARCHITECTURE.md` §3.1 regra 4 e 5 reescritas para Modelo B.
- `docs/SECURITY.md` regra 2 e 3 reescritas para Modelo B.
- `BACKEND.md` §4 e §6 atualizados.
- `0013_rpcs.sql` marcado como SUPERSEDED por 0016.
- `docs/DECISIONS.md`: ADR-009 indexado; nota Modelo B corrige "RPCs SECURITY
  INVOKER".

### Não implementado (próxima)
- Reset/replay from-scratch da cadeia 0001→0017 via dashboard (CLI/MCP não resetam
  o remoto com segurança; apply incremental + inventário + testes = PASS real; o
  reset from-scratch fica como hardening final da Sessão 05). → **Sessão 05**.

## [Sessão 05] — 2026-08-28 — Auth de usuários (Supabase Auth) + reset/replay from-scratch

### Adicionado
- **ADR-010** — ciclo de vida de identidade e autenticação (MVP). D1 email+senha;
  D2 trigger `handle_new_user`; D3 convites `invitations`+`accept_invitation` (anon
  não acessa; prova propriedade do email via login); D4 RPCs admin DEFINER; D4.1
  `is_platform_admin()` ≠ `is_super_or_admin()` (visibilidade vs. autoridade); D5 JWT
  DB-lookup sem custom claims; D6 cookie-based; D7 matriz de quem convida quem.
- **Migration 0018** — trigger `handle_new_user` `SECURITY DEFINER` on `auth.users`
  AFTER INSERT → `profiles` (`on conflict do nothing`). Garante FK de papéis/
  memberships/drivers → `profiles(id)`. Padrão Supabase.
- **Migration 0019** — `invitations` (RLS) + 6 RPCs `SECURITY DEFINER`:
  `create_invitation`, `accept_invitation`, `cancel_invitation`,
  `assign_platform_role`, `add_org_member`, `create_driver`. Helper `my_email()`
  (DEFINER) e `is_super_or_admin()` (super/admin, exclui operator). Idempotentes
  (`on conflict do nothing`); authz por `auth.uid()`. Grants least-privilege
  (authenticated: EXECUTE + SELECT em invitations sob RLS, sem DML direto; anon: nada).
- **`supabase/tests/test_vio10_auth_lifecycle.sql`** — 34 asserções (begin/rollback).
- **`supabase/config.toml`** — `minimum_password_length=12`,
  `password_requirements=lower_upper_letters_digits_symbols`,
  `enable_anonymous_sign_ins=false`, `[auth.sms] enable_signup=false` (MVP).

### Corrigido (durante a validação real)
- **0019 `create_invitation`**: `returning token` ambíguo (output param `token` vs.
  coluna) → alias `inv.token`. (42702)
- **0019 autoridade de mutação**: RPCs de mutação usavam `is_platform_admin()` (que
  inclui `operator`) → escalonamento de privilégio (operator atribuía papel, criava
  driver, cancelava convite alheio). Corrigido para `is_super_or_admin()`
  (super/admin). RLS de **visibilidade** de `invitations` mantém `is_platform_admin()`
  (operator vê — leitura, ADR-009). (ADR-010 D4.1)
- **`test_vio10_invariants.sql`**: `plan(12)` → `plan(13)` (rodava 13 asserções).
- **`test_vio10_authz.sql`**: inserts manuais em `profiles` agora `on conflict do
  nothing` (trigger 0018 cria o perfil; evita PK duplicada).

### Validado (real, no dev `rtoyfiqngyicqtuzwfhz` — nunca produção)
- **Reset from-scratch** via SQL (`drop schema public cascade; delete from auth.users;
  create schema public; grants`) + **replay 0001→0019 em ordem** — todos aplicam
  limpo (19/19, sem MIGFAIL).
- Inventário: 26 tabelas (incl. `invitations`), RLS em todas (26/26), trigger
  `handle_new_user` presente, `anon`=0 grants.
- `test_vio10_invariants.sql` → **13/13 PASS** (num_failed=0).
- `test_vio10_rpcs.sql` → **48/48 PASS** (num_failed=0).
- `test_vio10_authz.sql` → **21/21 PASS**.
- `test_vio10_auth_lifecycle.sql` → **34/34 PASS** (T1–T19: trigger, convites, authz
  do inviter, idempotência de accept, prova de email, expiração, driver via convite,
  RLS de invitations, anon bloqueado).
- Veredito **GO → Sessão 06**.

### Notas de infra
- Reset do dev feito via **SQL** (curl + Management API `/database/query`): não há
  endpoint de reset a nível de projeto (só branch). `drop schema public cascade` +
  `delete from auth.users` + recriar `public` funciona; o trigger em `auth.users`
  sobrevive ao drop de `public` (vive no schema `auth`), e 0018 o recria idempotente.
- Testes pgTAP (invariants/rpcs) executados wrapped em `begin;…rollback;` + veredicto
  `num_failed()` (o endpoint só devolve o último resultset; `finish()` sozinho perdia
  as linhas `ok`). authz/auth_lifecycle já consolidam resultado num único SELECT.

## [Sessão 06] — 2026-08-28 — Criação da corrida + gestão de empresas/veículos/entregadores

### Adicionado
- **ADR-011** — criação da corrida + gestão de entidades. D1 criação=`draft`+itens+
  evento `delivery_created` (sem preço; pricing é Sessão 07); D2 snapshots
  auto-contidos + ponto montado server-side (PostGIS); D3 `external_reference`=dedup
  (não retry); D4 matriz de autoridade de gestão (estende ADR-009); D5 mutação só via
  RPC DEFINER; D6 capture de ator por `auth.uid()`.
- **Migration 0020** — 6 RPCs `SECURITY DEFINER` de gestão: `create_organization`,
  `create_business`, `create_business_location`, `create_vehicle`, `set_current_vehicle`,
  `update_driver_status`. + `create unique index idx_vehicles_plate_uk on
  public.vehicles(plate)` (placa fisicamente única; `create_vehicle` idempotente via
  `on conflict (plate)`). Grants least-privilege (authenticated: EXECUTE, sem DML; anon:
  nada).
- **Migration 0021** — `create_delivery_request` `SECURITY DEFINER`: cria
  `delivery_requests` (`status='draft'`) + `delivery_items` (1:N) +
  `delivery_events` (`delivery_created`) numa transação. Authz system/admin/membro de
  org. Pontos montados server-side (PostGIS). `external_reference` dedup via `on
  conflict (organization_id, external_reference) do nothing` → `already_exists`.
  Pré-valida itens (jsonb array, `description` não-vazio, `quantity > 0`).
- **`supabase/tests/test_vio10_creation.sql`** — 37 asserções (begin/rollback + SELECT
  consolidado). Criação de org/business/location/vehicle/set_current_vehicle/
  update_driver_status/create_delivery_request; cross-tenant negado; admin/operator/
  system ok; `external_reference` dedup (mesma org vs outra org); location de outro
  business; itens vazios/malformados; `vehicle_required` null; pickup_lat null; ponto
  xy; evento `delivery_created`.

### Decisões
- **Criação = `draft` (sem preço)**: confirmado por `PRODUCT.md` (criação ≠ cálculo de
  preço), `DELIVERY_LIFECYCLE.md` (`draft → quoted` = sistema/pricing) e o schema
  (`delivery_requests` sem colunas de preço; preço em `delivery_quotes`). Pricing
  (cotação, `draft → quoted`) é **Sessão 07**.
- **Veículos driver-owned**: `create_vehicle` autoriza driver self (`drivers.user_id=
  auth.uid()`) ou super/admin. `create_driver` (0019) é admin-only (cria identidade);
  veículo é posse do driver.
- **`update_driver_status` (super/admin, sem system)**: fecha o lado driver do risco
  "offboarding/revogação" em aberto desde a Sessão 05 (account_status cobre
  ativo/suspenso/bloqueado). `remove_platform_role`/`remove_org_member` (revogação de
  papel/membership) ainda deferidos.

### Validado (real, no dev `rtoyfiqngyicqtuzwfhz` — nunca produção)
- **Reset from-scratch** via SQL + **replay 0001→0021 em ordem** — 21/21 limpo (sem
  MIGFAIL).
- Inventário: 26 tabelas (nenhuma nova), RLS 26/26, 7 novos RPCs `SECURITY DEFINER`
  (6 gestão + 1 criação), `vehicles.plate` unique, `anon`=0 grants em `public`
  (os grants `anon` em `realtime`/`storage` são schemas Supabase, não domínio).
- `test_vio10_invariants.sql` → **13/13 PASS**; `test_vio10_rpcs.sql` → **48/48 PASS**;
  `test_vio10_authz.sql` → **21/21 PASS**; `test_vio10_auth_lifecycle.sql` → **34/34
  PASS**; `test_vio10_creation.sql` → **37/37 PASS** — todas reais (não simulado).
- Veredito **GO → Sessão 07** (pricing engine determinístico).

### Corrigido (durante a validação real)
- **`test_vio10_creation.sql` T4**: bloco `create_vehicle` (driver self) não executava
  `set_config` antes — rodava sob JWT residual `uBO` (business_owner) →
  `not_authorized`. Adicionado `set_config(uDrv)` antes do bloco. T4b ajustado para
  chamar `create_vehicle(v_drv, …)` (mesmo driver, placa duplicada) em vez de `v_drv2`
  (que falhava authz antes do conflito de placa). 37/37 após o ajuste.

## [Sessão 10] — 2026-08-28 — Atribuição atômica em concorrência real (GATE de produção)

### Adicionado
- **ADR-015** — harness de concorrência real (GATE de produção, ADR-007). D1 mecanismo
  (curls paralelos ao Management API — `dblink_connect_u` negado/não-superuser, senha
  nunca na linha de comando; verificado empiricamente: N curls paralelos rodam em
  conexões backend separadas concorrentemente); D2 três races (A: 2 `claim_delivery`
  paralelos; B: 2 `select_winner_and_claim` paralelos; C: SWAC vs claim direto —
  observacional); D3 invariante do GATE (≤1 assignment ativa, exatamente 1 won,
  assigned, closed — determinístico no DB, vencedor não-determinístico); D4 achado de
  lock-ordering (SWAC round→delivery vs claim delivery→round-update — deadlock latente,
  não-hazard vivo, reproduzido empiricamente como 40P01 no Test C run 2, invariante
  sobreviveu); D5 sem migration/schema/grant novo; D6 critério de PASS (≥5 runs reais);
  D7 ambiente/segurança (dev only, nunca produção, PAT em `~/.supabase/vio10_dev_pat`).
- **`supabase/tests/concurrency_harness.sh`** + **`concurrency_setup.sql`** — artefato do
  GATE: reset + replay 0001→0024 + inventário + 8 suítes de regressão + harness de
  concorrência (3 races × N runs). Self-contained, paths relativos, gera `verdict.sql`.

### Decisões
- **Mecanismo do harness = curls paralelos ao Management API** (substitui `dblink` no
  arcabouço de teste de concorrência — reutilizável para futuros gates). `dblink_connect_u`
  é negado (role não-superuser); senha na linha de comando é vazamento (bloqueado).
- **Test C é observacional (DB-state only)**: SWAC vs claim direto tem lock-ordering
  divergente → pode deadlockar (40P01) → retorno RPC não-determinístico; o invariante de
  DB é determinístico e é o que se afirma.
- **Lock-ordering `claim_delivery`↔SWAC = dívida técnica observada, hardening adiado**:
  não é hazard vivo (`claim_delivery` só roda dentro de SWAC, mesma transação). Se um
  futuro camino chamar claim direto concorrente com SWAC, endurecer (claim adquirir round
  `FOR UPDATE` antes do delivery, espelhando SWAC) ou centralizar o close fora do claim.
- **Sem migration, sem schema/RPC/grant novo** — Sessão 10 é validação, não feature.

### Validado
- **GATE PASS**: invariante ADR-007 (≤1 `delivery_assignment` ativa por `delivery_request`)
  sustentado em **5 runs × 3 races = 15 corridas reais paralelas** (não simulado). Todas:
  `n_assign=1, n_won=1, n_lost=1, del_status='assigned', round_status='closed'`.
  - Test A: sempre 1 `true|won` + 1 `false|not_searching_driver`.
  - Test B: sempre 1 `true|won` + 1 `false|round_not_open`.
  - Test C: 1 vencedor + 1 perdedor; run 2 reproduziu 40P01 (deadlock) no SWAC —
    invariante sobreviveu (confirma empiricamente o achado D4).
- **Regressão (8 suítes) PASS**: invariants 13/13, rpcs 48/48, authz 21/21, auth_lifecycle
  34/34, creation 37/37, pricing 62/62, dispatch 65/65, bid 61/61. Reset + replay
  0001→0024 (24/24 limpo). Inventário: 26 tabelas, RLS 26/26, SWAC system-only, `anon`=0.

### Corrigido
- **Bug de harness (não de RPC)**: 1ª versão reusava longitudes entre os 5 runs → drivers
  perdedores de runs anteriores (active/available sem assignment) vazavam para a
  eligibility de runs posteriores → `n_lost` crescia (1,2,3,4,4). Invariante núcleo
  (`n_assign=1`, `n_won=1`) nunca violado. Corrigido com offset de 1°/run (~111km >> raio
  10km). Lição: poluição cross-RUN — isole por pickup geográfica distinta por run também.

## [Sessão 09] — 2026-08-28 — Bid engine (scoring + seleção + `claim_delivery` atômico)

### Adicionado
- **ADR-014** — bid engine. D1 `select_winner_and_claim` system-only (terceiro system-only
  após `create_quote`/`open_dispatch_round`; trust boundary de pesos de scoring); D2 fluxo
  (validate → coletar → 0: fechar manual | ≥1: pontuar → claim); D3 candidatos válidos =
  responded + ainda-eligible (re-valida eligibility no close); D4 scoring min-max + pesos
  de param + tie-break determinístico; D5 seleção ≠ confirmação (`claim_delivery` confirma);
  D6 auditoria via `delivery_events` (scores no metadata, sem coluna de winner); D7 ator
  via `auth.uid` (system); D8 sem novos grants de DML a `authenticated`, sem tabela/coluna
  nova.
- **Migration 0024** — 1 RPC `SECURITY DEFINER` system-only: `select_winner_and_claim`
  (`search_path = public, extensions, pg_catalog` — PostGIS `ST_Distance`/`ST_DWithin`).
  **Nenhuma tabela/coluna nova** — tudo já existe em 0005/0009/0010/0016. Grants: `revoke
  public` + `execute` só a `service_role` (`authenticated` sem EXECUTE — defesa em
  profundidade); `anon`: nada. Fecha a rodada, pontua candidatos válidos (min-max de
  `bid_amount_cents` + `ST_Distance`, pesos de param, tie-break `score desc, dist_m asc,
  responded_at asc, driver_id asc`), escolhe vencedor, chama `claim_delivery` atomicamente
  (alias `as t` + `t.won, t.reason` — lição da Sessão 07). Sem vencedor → fecha rodada +
  expira pending + `round_closed` (no_candidates) + retorna `no_candidates`. Com vencedor
  → `winner_selected` (scores no metadata) + `claim_delivery` (atribui, fecha rodada,
  R16, `driver_assigned`). Claim race → fecha como superseded + retorna o reason.
- **`supabase/tests/test_vio10_bid.sql`** — 61 asserções (begin/rollback + SELECT
  consolidado). T1 basic win (todos accept, bids iguais → mais próximo); T2 no_candidates
  (decline + pending→expired); T3 counter_bid (distâncias iguais → menor bid); T4
  weight_price=0 (mais próximo independente do bid); T5 weight sensitivity (1/1 → d2,
  2/1 → d3); T6 eligibility re-check (assignment race → próximo); T7 re-check (offline);
  T8 expired offer excluded; T9 round_already_closed → `round_not_open`; T10 wrong_state
  (cancelled); T11 system-only (`not_authorized` vs won); T12 invalid_param (pesos 0,
  negativo, max_age<=0); T13 tie-break (score idêntico → driver_id asc); T14 fator
  constante (nullif); T15 raio progressivo (round1 raio 2000 → 1 candidato no_candidates
  → round2 raio 6000 → 2 candidatos, round_number=2, win); T16 not_found. Geometria
  isolada por cenário (cada teste pickup em longitude distinta B=N.0, drivers em B+off;
  bases ~111km aparte → sem poluição cross-scenario via `ST_DWithin`).

### Decisões
- **1 RPC system-only `select_winner_and_claim`**: fecha a rodada, pontua in-DB, escolhe
  vencedor, chama `claim_delivery` internamente. Sem vencedor → fecha + `no_candidates`.
  Espelha o padrão system-only de `create_quote`/`open_dispatch_round`. `BACKEND.md` §4 já
  previa `select_winner_and_claim`.
- **Scoring: `bid_amount_cents` + distância PostGIS, ETA peso 0** até o RoutingProvider
  (Sessão 20); distância como proxy operacional. Pesos como params do caller (backend),
  sem `scoring_config` table no MVP (adiada).
- **Tie-break determinístico** (definido no ADR, não ditado por ADR-006): `score desc,
  dist_m asc, responded_at asc, driver_id asc`. `now()` constante numa transação → em
  testes single-tx o tie-break cai para `driver_id` asc; a ordem `responded_at` é
  exercitada em concorrência real na Sessão 10 (GATE).
- **Sem `winner_*` em `dispatch_rounds`**: vencedor em `delivery_assignments` (active) +
  `delivery_offers.status='won'` + `delivery_events`. **Nenhuma tabela/coluna nova.**
- **Sem early-close arbitrária no MVP** (ADR-006): MVP espera o timeout da janela; early
  close futuro só por regra determinística explícita (`candidate_score >=
  fast_accept_threshold`), nunca "primeiro que aceitar ganha".

### Validado (real, no dev `rtoyfiqngyicqtuzwfhz` — nunca produção)
- **Reset from-scratch** via SQL + **replay 0001→0024 em ordem** — 24/24 limpo (sem
  MIGFAIL).
- Inventário: 26 tabelas (nenhuma nova), RLS 26/26, `select_winner_and_claim` `SECURITY
  DEFINER` system-only (execute só service_role — `swac_exec_grants=1`, authenticated sem
  EXECUTE), `anon`=0 grants em `public`.
- `test_vio10_invariants.sql` → **13/13 PASS**; `test_vio10_rpcs.sql` → **48/48 PASS**;
  `test_vio10_authz.sql` → **21/21 PASS**; `test_vio10_auth_lifecycle.sql` → **34/34
  PASS**; `test_vio10_creation.sql` → **37/37 PASS**; `test_vio10_pricing.sql` → **62/62
  PASS**; `test_vio10_dispatch.sql` → **65/65 PASS**; `test_vio10_bid.sql` → **61/61
  PASS** — todas reais (não simulado).
- Veredito **GO → Sessão 10** (atribuição atômica em concorrência real — GATE de produção).

### Corrigido (durante a validação real)
- **Poluição de drivers cross-scenario (5 falhas)**: a 1ª versão do `test_vio10_bid.sql`
  usava pickup `(0,0)` para todos os cenários + drivers em lat=0 — no single-tx
  (`begin;…rollback;`), drivers de testes anteriores (ainda active/available/fresh, sem
  assignment) vazavam para `open_dispatch_round` de testes posteriores (todos a ≤5000m do
  pickup compartilhado); com `max_candidates=10`, polluters mais próximos crowding-out os
  drivers-alvo (T5a/T5b vencedor errado; T15 round1/round2 count=10 em vez de 1/2). Corrigido
  dando a cada cenário uma longitude de pickup distinta (`B=N.0`, N=1..15) e colocando os
  drivers do teste em `B+off` — bases ~111km aparte isolam via `ST_DWithin`. Mais uma
  asserção invertida (`T2_no_winner` expected `'f'`→`'t'`: no_candidates retorna
  `winner_driver_id` null, e a asserção `winner_driver_id is null → 't'` tinha expected
  errado). 61/61 após o ajuste.
- **Nenhum bug na RPC em runtime**: as lições da Sessão 07 (ambiguidade `as t` ao chamar
  `claim_delivery`) e da Sessão 08 (PostGIS em `extensions`, não-qualificado) foram
  aplicadas proativamente em 0024 — replay 24/24 + suíte bid 61/61 na 2ª execução (apenas
  bugs de teste, não de RPC).

## [Sessão 08] — 2026-08-28 — Dispatch engine (busca de candidatos + raio progressivo)

### Adicionado
- **ADR-013** — dispatch engine. D1 `confirm_quote` user-scoped (membro da org/operator/
  admin/system confirma a cotação pendente; transition-first `quoted→searching_driver`,
  marca quote `confirmed`+`confirmed_at`, sem órfã); D2 `open_dispatch_round` system-only
  (segundo system-only após `create_quote`; trust boundary de insumos de dispatch);
  D3 eligibility MVP (active+available+veículo compatível+sem assignment ativa+localização
  fresca+`ST_DWithin` no raio); D4 criação atômica de rodada+offers; D5 raio progressivo
  orquestrado (não no RPC); D6 atomicidade/guards; D7 ator via `auth.uid`; D8 sem novos
  grants de DML a `authenticated`, sem tabela nova.
- **Migration 0023** — 2 RPCs `SECURITY DEFINER`: `confirm_quote` (user-scoped,
  `search_path = public, pg_catalog`) e `open_dispatch_round` (system-only,
  `search_path = public, extensions, pg_catalog` — PostGIS `ST_DWithin`/`ST_Distance`).
  **Nenhuma tabela/coluna nova** — tudo já existe em 0005/0009/0010. Grants: `confirm_quote`
  → `service_role`+`authenticated` (user-facing); `open_dispatch_round` → `service_role`
  somente (`authenticated` sem EXECUTE, defesa em profundidade); `anon`: nada.
- **`supabase/tests/test_vio10_dispatch.sql`** — 65 asserções (begin/rollback + SELECT
  consolidado). `confirm_quote` (membro org; authz wrong-org/system/re-confirm/wrong_state/
  expired); `open_dispatch_round` (rodada 1 raio 2000 → 2 candidatos; system-only;
  eligibility radius 500 → 1; max_candidates=2 radius 5000 → 2; round_already_open; raio
  progressivo round 2 radius 5000 → 3 candidatos round_number=2; wrong_state quoted/assigned/
  notfound; 0 candidatos radius 50; invalid_param). Geometria no equador (lat=0) para
  distâncias determinísticas (1° lng ≈ 111320m).

### Decisões
- **2 RPCs, 2 trust boundaries**: `confirm_quote` (user-scoped) confirma; `open_dispatch_round`
  (system-only) abre cada rodada. Componível: orquestrador chama N vezes (raio progressivo).
  Alinha "Backend decide, n8n orquestra".
- **Parâmetros do caller (backend), sem `dispatch_config`**: `open_dispatch_round` recebe
  raio/max_candidates/driver_offer/janela/max_location_age como params; tabela de config
  adiada no MVP (espelha `create_quote`).
- **`service_areas` por entregador ADIADO**: candidatos filtrados só por raio até a coleta
  (`ST_DWithin`) + eligibility; sem junction driver↔area hoje.
- **`offered` reservado**: não muta `current_availability_status` ao criar offers; driver
  permanece `available`, pode receber offers de rodadas distintas; guard contra dupla offer
  na mesma rodada = UK `(dispatch_round_id, driver_id)`.
- **Cria rodada mesmo com 0 candidatos** (audit snapshot; orquestrador sabe expandir o raio).

### Validado (real, no dev `rtoyfiqngyicqtuzwfhz` — nunca produção)
- **Reset from-scratch** via SQL + **replay 0001→0023 em ordem** — 23/23 limpo (sem
  MIGFAIL).
- Inventário: 26 tabelas (nenhuma nova), RLS 26/26, `confirm_quote` `SECURITY DEFINER`
  (execute service_role+authenticated), `open_dispatch_round` `SECURITY DEFINER`
  system-only (execute só service_role, **authenticated sem EXECUTE**), `anon`=0 grants
  em `public`.
- `test_vio10_invariants.sql` → **13/13 PASS**; `test_vio10_rpcs.sql` → **48/48 PASS**;
  `test_vio10_authz.sql` → **21/21 PASS**; `test_vio10_auth_lifecycle.sql` → **34/34
  PASS**; `test_vio10_creation.sql` → **37/37 PASS**; `test_vio10_pricing.sql` → **62/62
  PASS**; `test_vio10_dispatch.sql` → **65/65 PASS** — todas reais (não simulado).
- Veredito **GO → Sessão 09** (bid engine + atribuição atômica — GATE).

### Notas de validação
- **pgTAP `finish()` neste dev emite via RAISE** (0 rows no resultset do endpoint); o
  veredito `num_failed()=0` é a autoridade, e o último resultset de cada suíte pgTAP
  confirma o nº de testes ("ok 13"/"ok 48"). O `finish()`-based `test_lines` no wrapper
  `verdict.sql` é não-confiável aqui (sempre 0); `num_failed()` é o sinal real. Inalterado
  desde a Sessão 05.
- **PostGIS em schema `extensions`**: `open_dispatch_round` usa `st_dwithin`/`st_distance`
  **não-qualificados** (não `public.st_*`) com `set search_path = public, extensions,
  pg_catalog` — mesmo padrão de 0021. Funções PostGIS vivem em `extensions`, não em
  `public`.

## [Sessão 07] — 2026-08-28 — Pricing engine determinístico (cotação, `draft → quoted`)

### Adicionado
- **ADR-012** — pricing engine determinístico. D1 `create_quote` system-only (primeiro
  RPC system-only; `auth.uid() not null` → `not_authorized`; trust boundary de insumos
  de rota); D2 álgebra determinística (`customer=subtotal+fee`, `driver=subtotal−fee`,
  `distance_component` ceil inteiro, `vehicle`/`dynamic`=0 no MVP, `subtotal=greatest
  (raw,min_price)`); D3 faixa min/max real via multipliers; D4 seleção de regra
  org→global→`no_pricing_rule`; D5 atomicidade transition-first; D6 ator via `auth.uid`;
  D7 TTL 900s `pending`; D8 idempotência por estado.
- **Migration 0022** — `create_quote` `SECURITY DEFINER` (system-only) + ALTERs em
  `pricing_rules` (+`min_multiplier`/`max_multiplier` numeric(5,4)) e `delivery_quotes`
  (+`min/max_customer_price_cents`/`min/max_driver_offer_cents`). **Nenhuma tabela nova.**
  Grants: `revoke public` + `execute` só a `service_role` (`authenticated` sem EXECUTE —
  defesa em profundidade); `anon`: nada.
- **`supabase/tests/test_vio10_pricing.sql`** — 62 asserções (begin/rollback + SELECT
  consolidado). Cotação moto standard (componentes, subtotal, customer/driver, faixa
  min/max, snapshot, status `quoted`, `quoted_at`, evento `quote_created` com
  `quote_id`); urgent; carro vs moto; `min_price` floor; faixa não-degenerada;
  `pricing_error` (driver<0); `no_pricing_rule`; fallback global; `wrong_state`;
  `invalid_distance`/`invalid_duration`; authz (autenticado → `not_authorized`, system
  → ok); `distance_component` ceil (1001m).

### Decisões
- **Faixa min/max real** (não cotação única): o motor calcula piso+teto via multipliers;
  `customer_price`/`driver_offer` = alvo; min/max = faixa ao business / banda de lances.
- **`create_quote` system-only**: insumos de pricing (distância/duração) vêm do backend
  (provider na Sessão 20), não do business; o dashboard chama um Route Handler do
  backend, que chama `create_quote` system-scoped (Sessão 18).
- **`vehicle_component`/`dynamic_component` = 0 no MVP**: custo do veículo codificado
  pela regra por `vehicle_type`; demanda/pico deferido (sem coluna de config).
- **`per_minute_cents` reservado**: não usado na fórmula MVP (componentes do doc não
  incluem duration); `duration_seconds` é snapshot. Reuso futuro.

### Validado (real, no dev `rtoyfiqngyicqtuzwfhz` — nunca produção)
- **Reset from-scratch** via SQL + **replay 0001→0022 em ordem** — 22/22 limpo (sem
  MIGFAIL).
- Inventário: 26 tabelas (nenhuma nova), RLS 26/26, `create_quote` `SECURITY DEFINER`
  (primeiro system-only), `pricing_rules`+multipliers, `delivery_quotes`+min/max,
  `authenticated` **sem EXECUTE** em `create_quote` (`service_role` com EXECUTE),
  `anon`=0 grants em `public`.
- `test_vio10_invariants.sql` → **13/13 PASS**; `test_vio10_rpcs.sql` → **48/48 PASS**;
  `test_vio10_authz.sql` → **21/21 PASS**; `test_vio10_auth_lifecycle.sql` → **34/34
  PASS**; `test_vio10_creation.sql` → **37/37 PASS**; `test_vio10_pricing.sql` →
  **62/62 PASS** — todas reais (não simulado).
- Veredito **GO → Sessão 08** (dispatch: busca de candidatos + raio progressivo).

### Corrigido (durante a validação real)
- **Ambiguidade PL/pgSQL em `create_quote` (0022)**: `select ok, reason from
  transition_delivery(...)` era ambíguo (ERRO 42702) — os nomes das colunas de saída de
  `create_quote` (`returns table(ok, reason, quote_id)`) viram variáveis implícitas no
  corpo, conflitando com as colunas do retorno de `transition_delivery`. Corrigido
  aliasando a subquery: `from transition_delivery(...) as t` e referindo `t.ok, t.reason`.
  **Lição:** `create or replace function` não executa o corpo ao aplicar a migration —
  replay 22/22 "limpo" não garante que a função funciona; a suíte que exerce a RPC pega o
  bug em runtime. Sempre rodar a suíte da RPC, não só confiar no replay.
- **`test_vio10_pricing.sql`**: dois bugs de teste — `insert into pr_results ... values
  (t, exp, exp=act)` tinha 3 valores para 4 colunas (faltava `act`); `(quoted_at is not
  null)::text` devolve `'true'`/`'false'` (não `'t'`/`'f'`) — trocado por `case`. 62/62
  após os ajustes.

## [Sessão 01] — 2026-08-27 — Diagnóstico
- Repositório confirmado greenfield.
- Arquitetura proposta e aprovada com ajustes (ver Sessão 02).