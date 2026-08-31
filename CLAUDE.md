# CLAUDE.md — Guia do projeto ViO10

> Este arquivo é o ponto de entrada para qualquer sessão do Claude Code neste repositório.
> Ele carrega o contexto mínimo necessário para entender o ViO10 e trabalhar de forma
> consistente. Documentação detalhada vive nos arquivos referenciados abaixo.

## O que é o ViO10

O ViO10 é uma **plataforma de logística local e fretes rápidos**. O objetivo inicial é
operar em **Congonhas/MG**, conectando estabelecimentos comerciais locais a entregadores
(prioritariamente motociclistas) para entregas rápidas de produtos.

Não é um delivery de alimentos. É um **motor inteligente de despacho e contratação de
fretes locais**.

Fluxo macro: empresa solicita → sistema entende origem/destino/produto/urgência/veículo →
calcula faixa de preço → localiza entregadores elegíveis → oferece oportunidade →
entregadores aceitam o valor **ou enviam um lance** → sistema avalia candidatos → **um**
entregador recebe a corrida (atomicamente) → acompanha coleta e entrega → conclui e
registra.

## Regra mestra (leia antes de qualquer decisão técnica)

> **Banco é a fonte da verdade. Backend decide. n8n orquestra. IA interpreta.
> DataCrazy comunica. Frontend apresenta e coleta ações.**

- Nenhuma camada externa altera diretamente estado operacional/financeiro crítico.
- n8n e DataCrazy **não** escrevem no banco diretamente. Eles chamam o backend.
- IA não inventa preço, ETA, entregador ou status. Esses dados vêm do sistema.
- Frontend nunca inventa estado; consome estado oficial do backend.

## Stack aprovada

- **Next.js 16.3.3** (Active LTS) — App Router, TypeScript, Tailwind CSS, shadcn/ui.
  Não usar Next.js 15 como base greenfield. Confirmar patch 16.x mais recente no momento
  de inicializar dependências; sem versões beta/canary sem justificativa.
- **Supabase** — PostgreSQL + Auth + Storage + RLS + Realtime.
- **n8n** self-hosted — orquestrador, **não** fonte da verdade.
- **DataCrazy / WhatsApp** (Crazy IA) — mensageria e IA conversacional.
- **Google Maps Platform** — provider geográfico inicial, atrás de abstração.

Dinheiro sempre em **inteiros (centavos)**. `R$ 10,90 = 1090`. Nunca float para finança.

## Camadas e fronteiras

```
UI (React/Next) → application/service → domain → persistence/RPC (Postgres)
```

- **Route Handlers/API** para integrações externas (n8n, DataCrazy).
- **Server Actions** somente para ações originadas no próprio frontend.
- **Funções/RPC do Postgres** para operações que exigem atomicidade
  (atribuição de corrida, transições de estado críticas).
- n8n e DataCrazy **não** dependem de Server Actions internas.

## Tenancy

`organization` (tenant / conta contratante, limite primário de RLS)
→ `business` (negócio/marca operado pelo tenant)
→ `business_location` (unidade física).

MVP normalmente 1:1:1, mas o modelo suporta multi-unidade sem reconstrução.

## Estados da corrida

`draft → quoted → searching_driver → assigned → driver_to_pickup → at_pickup →
picked_up → in_transit → delivered` (+ terminais `cancelled`, `failed`, `expired`).

**`bidding` NÃO é estado principal.** A disputa ocorre *dentro* de `searching_driver`,
via `dispatch_rounds` / `delivery_offers` / `bids`.

### Semântica do sistema de lances (correção crítica da Sessão 01)

> **ACEITAR ≠ GANHAR.** ACEITAR = "estou disposto a fazer a corrida pelo valor ofertado",
> i.e. um lance igual a `driver_offer_cents`.

- O primeiro a clicar ACEITAR **não** ganha automaticamente.
- A rodada coleta candidatos numa janela configurada, fecha, pontua, escolhe o
  vencedor e só então executa `claim_delivery()` atomicamente.
- Early close futuro só por regra determinística explícita (ex.: `candidate_score >=
  fast_accept_threshold`), nunca "primeiro que aceitar ganha".

## Convenções do repositório

- Commits e documentação em **português**.
- Toda decisão arquitetural relevante vira um **ADR** em `docs/adr/`.
- Toda transição crítica de corrida passa por função central transacional — ninguém
  seta `status` direto no banco via app.
- Webhooks/mensagens/pagamentos são **idempotentes** (`idempotency_key`,
  `external_event_id`).
- Toda alteração relevante em corrida gera `delivery_event` (auditoria).

## Documentação

| Arquivo | Conteúdo |
|---|---|
| `ARCHITECTURE.md` | Arquitetura completa, camadas, fronteiras, diagramas |
| `BACKEND.md` | Estrutura do backend, layering, RPC, idempotência |
| `FRONTEND.md` | 3 superfícies (driver/admin/business), PWA, convenções |
| `PLAN.md` | Roadmap por fases, status atual, próxima etapa |
| `CODE_REVIEW.md` | Log de revisões e security review |
| `CHANGELOG.md` | Histórico de mudanças |
| `docs/PRODUCT.md` | Produto, escopo MVP, usuários, fluxos |
| `docs/DELIVERY_LIFECYCLE.md` | Máquina de estados da entrega |
| `docs/DISPATCH_ENGINE.md` | Busca de candidatos, rodadas, raio progressivo |
| `docs/BID_ENGINE.md` | Semântica de ACEITAR/lance, scoring, atribuição |
| `docs/PRICING_ENGINE.md` | Pricing determinístico, composição do preço |
| `docs/N8N_WORKFLOWS.md` | Mapa de workflows n8n |
| `docs/DATACRAZY_INTEGRATION.md` | Limites DataCrazy/IA, fluxos WhatsApp |
| `docs/SECURITY.md` | RLS, authz, idempotência, auth/convite, links assinados, secrets |
| `docs/GEOLOCATION.md` | Abstração de provider, Google Maps, TWO_WHEELER |
| `docs/DECISIONS.md` | Log consolidado de decisões |
| `docs/adr/` | ADRs ADR-001 em diante (até ADR-022) |

## Estado atual

- **Sessão 01**: diagnóstico aprovado.
- **Sessão 02**: fundação documental (docs-mãe + ADRs).
- **Sessão 03**: fundação do banco (14 migrations, 4 RPCs, RLS default deny).
- **Sessão 03.5 (concluída)**: validação real da fundação — **PASS**. Testes
  executados server-side (sem Docker): pgTAP 12/12, RPCs 48/48, concorrência
  `claim_delivery` (exatamente 1 vencedor), `delivery_events` imutável, RLS e grants
  default-deny confirmados. Correções: PostGIS search_path, 0014 endurecido (auto-grants
  Supabase), R16 cross-round, R17 (`external_reference` ≠ `idempotency_key`),
  `service_role` user-scoped vs system-scoped.
- **Sessão 04 (concluída)**: Auth/Grants/RLS/RBAC — **PASS (Modelo B)**. 17 migrations
  (0016 RPCs `SECURITY DEFINER` + checagem `auth.uid()`; 0017 RLS policies + 5 helpers
  DEFINER). ADR-009 matriz RBAC. Grants least-privilege (0015). Validado real no dev:
  authz 21/21, system-path claim 4/4, R16 cross-round, concorrência exatamente 1
  vencedor, bypass PostgREST FECHADO, inventário consistente.
- **Sessão 05 (concluída)**: Auth de usuários (Supabase Auth) + reset/replay
  from-scratch — **PASS**. 19 migrations (0018 trigger `handle_new_user` DEFINER on
  `auth.users` AFTER INSERT → `profiles`; 0019 `invitations` + 6 RPCs DEFINER de
  identidade/convite + helpers `my_email()`, `is_super_or_admin()`). ADR-010 (email+senha,
  trigger de perfil, convites com prova de email via login, JWT DB-lookup sem custom
  claims, cookie-based). `config.toml` (senha forte 12, sem anon/phone). Bug de
  escalonamento de privilégio corrigido na validação: mutação usava `is_platform_admin()`
  (inclui `operator`) → `is_super_or_admin()` (super/admin); visibilidade mantém
  `is_platform_admin()` (ADR-010 D4.1). Hardening final: reset via SQL + replay
  0001→0019 limpo (19/19); invariants 13/13, rpcs 48/48, authz 21/21, auth_lifecycle
  34/34 PASS. Risco "reset/replay não executado" (Sessão 04) FECHADO.
- **Sessão 06 (concluída)**: Criação da corrida + gestão de empresas/veículos/
  entregadores — **PASS**. 21 migrations (**0020** 6 RPCs DEFINER de gestão +
  `idx_vehicles_plate_uk`; **0021** `create_delivery_request` DEFINER). ADR-011
  (criação=`draft`+itens+evento `delivery_created`, sem preço; snapshots auto-contidos;
  pontos PostGIS server-side; `external_reference`=dedup; matriz de autoridade D4;
  mutação só via RPC DEFINER; capture de ator por `auth.uid()`). `update_driver_status`
  (super/admin, sem system) fecha o lado driver do risco offboarding. Nenhuma tabela
  nova. Hardening: reset via SQL + replay 0001→0021 limpo (21/21); invariants 13/13,
  rpcs 48/48, authz 21/21, auth_lifecycle 34/34, creation 37/37 PASS. Bug T4 corrigido
  na validação (JWT residual em `create_vehicle`).
- **Sessão 07 (concluída)**: Pricing engine determinístico (cotação, `draft → quoted`)
  — **PASS**. 22 migrations (**0022** `create_quote` DEFINER; altera `pricing_rules`
  +`min/max_multiplier` e `delivery_quotes` +min/max customer/driver; **nenhuma tabela
  nova**). ADR-012 (D1 `create_quote` **system-only** — primeiro RPC system-only,
  `auth.uid() not null`→`not_authorized`, trust boundary de insumos de rota do backend;
  D2 álgebra `customer=subtotal+fee`/`driver=subtotal−fee`, `distance_component` ceil
  inteiro, `vehicle`/`dynamic`=0 no MVP; D3 faixa min/max via multipliers; D4 regra
  org→global→`no_pricing_rule`; D5 atomicidade transition-first; D6 ator via `auth.uid`;
  D7 TTL 900s `pending`; D8 idempotência por estado). Grants: `revoke public` + `execute`
  só a `service_role` (`authenticated` sem EXECUTE; `anon` nada). Hardening: reset via
  SQL + replay 0001→0022 limpo (22/22); invariants 13/13, rpcs 48/48, authz 21/21,
  auth_lifecycle 34/34, creation 37/37, pricing 62/62 PASS. Bug de ambiguidade PL/pgSQL
  corrigido na validação (`select ok, reason`→ alias `t.ok, t.reason` — colunas de saída
  de `returns table` viram variáveis implícitas).
- **Sessão 08 (concluída)**: Dispatch engine (busca de candidatos + raio progressivo,
  `quoted → searching_driver`) — **PASS**. 23 migrations (**0023** 2 RPCs DEFINER:
  `confirm_quote` user-scoped + `open_dispatch_round` system-only; **nenhuma tabela nova**).
  ADR-013 (D1 `confirm_quote` user-scoped confirma cotação pendente, transition-first,
  marca quote `confirmed`+`confirmed_at`; D2 `open_dispatch_round` system-only, segundo
  system-only, trust boundary de insumos de dispatch; D3 eligibility MVP —
  active+available+veículo compatível+sem assignment ativa+localização fresca+`ST_DWithin`
  no raio, `service_areas` por entregador adiado; D4 criação atômica de rodada+offers; D5
  raio progressivo orquestrado; D6 atomicidade/guards; D7 ator via `auth.uid`; D8 sem
  novos grants de DML a `authenticated`, sem tabela nova). `offered` reservado (não muta
  availability; guard dupla offer = UK round+driver). Hardening: reset via SQL + replay
  0001→0023 limpo (23/23); invariants 13/13, rpcs 48/48, authz 21/21, auth_lifecycle 34/34,
  creation 37/37, pricing 62/62, dispatch 65/65 PASS. Lições da Sessão 07 (ambiguidade
  `as t` + PostGIS em `extensions` não `public`) aplicadas proativamente — nenhum bug em
  runtime. pgTAP `finish()` neste dev emite via RAISE (0 rows); `num_failed()=0` é a
  autoridade.
- **Sessão 09 (concluída)**: Bid engine (scoring + seleção + `claim_delivery` atômico,
  `searching_driver → assigned`) — **PASS**. 24 migrations (**0024**
  `select_winner_and_claim` DEFINER system-only; **nenhuma tabela/coluna nova** — tudo já
  existe em 0005/0009/0010/0016). ADR-014 (D1 `select_winner_and_claim` **system-only** —
  terceiro system-only, trust boundary de pesos de scoring; D2 fluxo validate→coletar→
  0: fechar manual | ≥1: pontuar→claim; D3 candidatos válidos = responded + ainda-eligible,
  re-valida eligibility no close; D4 scoring min-max de `bid_amount_cents` + `ST_Distance`
  PostGIS, pesos de param, tie-break determinístico `score desc, dist_m asc, responded_at
  asc, driver_id asc`; D5 seleção≠confirmação — `claim_delivery` confirma; D6 auditoria via
  `delivery_events` — scores no metadata, sem `winner_*` em `dispatch_rounds`; D7 ator
  system; D8 sem novos grants de DML a `authenticated`, sem tabela/coluna nova). ACEITAR ≠
  GANHAR garantido no close + claim atômico. Raio progressivo: sem vencedor →
  `no_candidates` → orquestrador abre a próxima rodada. Grants: `revoke public` +
  `execute` só a `service_role` (`authenticated` sem EXECUTE — defesa em profundidade).
  Hardening: reset via SQL + replay 0001→0024 limpo (24/24); invariants 13/13, rpcs 48/48,
  authz 21/21, auth_lifecycle 34/34, creation 37/37, pricing 62/62, dispatch 65/65, bid
  61/61 PASS. Bugs de teste corrigidos (poluição cross-scenario via pickup compartilhado em
  single-tx → isolamento por longitude; asserção T2 invertida). Nenhum bug de RPC em
  runtime (lições Sessão 07/08 — ambiguidade `as t` e PostGIS em `extensions` — aplicadas
  proativamente). `searching_driver → assigned` só via `select_winner_and_claim` →
  `claim_delivery`.
- **Sessão 10 (concluída)**: Atribuição atômica em concorrência real — **GATE de produção
  PASS** (ADR-007/ADR-015). Invariante ≤1 `delivery_assignment` ativa por `delivery_request`
  validada em **concorrência real** (backends concorrentes em conexões separadas, não
  single-transaction). Mecanismo do harness: **curls paralelos ao Management API**
  (`dblink_connect_u` negado/não-superuser; senha nunca na linha de comando — verificado
  empiricamente: N curls paralelos rodam concorrentemente). 5 runs × 3 races (A: 2
  `claim_delivery` paralelos → 1 `won`+1 `not_searching_driver`; B: 2
  `select_winner_and_claim` paralelos → 1 `won`+1 `round_not_open`; C: SWAC vs claim direto
  → 1 vencedor) — todas sustentaram `n_assign=1, n_won=1, assigned, closed`. **Achado D4**:
  lock-ordering `claim_delivery`(delivery→round-update) ↔ SWAC(round→delivery) — deadlock
  latente (40P01, reproduzido no Test C run 2, invariante sobreviveu); **não-hazard vivo**
  (`claim_delivery` só roda dentro de SWAC, mesma tx); hardening adiado (dívida técnica
  observada). **Sem migration/schema/RPC/grant novo** — Sessão 10 é validação. Harness
  commitado: `supabase/tests/concurrency_harness.sh` + `concurrency_setup.sql`. Hardening:
  reset via SQL + replay 0001→0024 (24/24); invariants 13/13, rpcs 48/48, authz 21/21,
  auth_lifecycle 34/34, creation 37/37, pricing 62/62, dispatch 65/65, bid 61/61 PASS
  (regressão). Bug de harness corrigido (poluição cross-run via longitude compartilhada →
  offset 1°/run; invariante núcleo nunca violado).
- **Sessão 11 (concluída)**: Ciclo completo (máquina de estados pós-`assigned` + POD gate)
  — **PASS**. 26 migrations (**0025** schema prep — enum `pod_submitted` + unique
  `(delivery_request_id, pod_type)` em `proof_of_delivery`, sem funções; **0026** 3 RPCs
  `SECURITY DEFINER`: `transition_delivery` **refinada** (assinatura inalterada — matriz
  ator×transição D1, limite de reatribuição via metadata D2, cancelled/failed reason D3,
  POD gate D5, `draft→cancelled` em M), `submit_proof_of_delivery` (driver-scoped/system;
  valida + insere + emite `pod_submitted`; **não transita**), `confirm_delivery`
  **system-only** (valida POD + chama `transition_delivery('delivered')` que re-valida o
  gate). **Nenhuma tabela/coluna nova.** ADR-016 (D1 matriz ator×transição — system/admin/
  driver/business, M estrutural primeiro depois R de papel; D2 limite via
  `metadata.max_reassignments`; D3 reasons do metadata; D4 POD two-phase — "Submeter POD ≠
  entregue" análogo a ACEITAR ≠ GANHAR; D5 POD gate defense in depth; D6 completude MVP; D7
  ator via `auth.uid`; D8 sem tabela nova; D9 split 0025/0026 — gotcha `ALTER TYPE ... ADD
  VALUE` in-tx). Callers internos preservados (`create_quote`/`confirm_quote`); GATE Sessão
  10 íntegro. Grants: transition/submit → service_role+authenticated; confirm →
  service_role somente (authenticated sem EXECUTE). Hardening: reset via SQL + replay
  0001→0026 limpo (26/26); invariants 13/13, rpcs 48/48, authz 21/21, auth_lifecycle 34/34,
  creation 37/37, pricing 62/62, dispatch 65/65, bid 61/61, lifecycle 65/65 PASS — **9/9
  suítes, 406 asserções, sem regressão**. Bug de teste corrigido (leak residual de JWT —
  `set_config(...,true)` is_local persiste até o fim da transação, não do bloco; lição
  Sessão 06 reconfirmada: cada bloco autenticado reseta JWT para `'{}'` antes dos helpers,
  seta o ator, reseta antes de system-only). `test_vio10_rpcs` TR8 ajustado (POD gate exige
  POD antes de `in_transit→delivered`).
- **Sessão 12 (concluída)**: POD completo (OTP do recebedor, gate de geo, gate de pickup POD,
  Storage) — **PASS (com ressalva)**. 28 migrations (**0027** schema prep — enum `otp_generated`
  + tabela `delivery_otps` (unique `delivery_request_id`, delivery-only; hash salt+sha256,
  TTL, lockout) + RLS/grants + helper `is_assigned_driver_of` + bucket `pod-photos` (privado)
  + policy `pod_photos_insert` em `storage.objects`; **0028** 4 RPCs DEFINER). ADR-017 (D1
  OTP em `delivery_otps` com geração **system-only** `generate_delivery_otp` (5º system-only;
  código crypto 6 dígitos, hash salt+sha256, upsert, emite `otp_generated`; driver não vê o
  código antes do recebedor — trust boundary do OTP) + validação no `submit_proof_of_delivery`
  com `for update` (match → `consumed_at=now()` na mesma tx do insert; foto-only pula);
  D2 gate de geo em `in_transit→delivered` (configurável via `metadata.geo_tolerance_m`,
  default 200m, `st_distance`, skip se POD sem location); D3 gate de pickup POD em
  `at_pickup→picked_up` (`pickup_pod_required`); D4 verificação do recebedor = OTP match
  (foto = evidência, either-or preservado); D5 Storage `pod-photos` privado + RLS INSERT
  p/ driver com assignment ativa; D6 camada externa n8n/WhatsApp **especificada**, validação
  live **deferida** (sem simular PASS); D7 sem coluna `verified`; D8 split 0027/0028
  (gotcha enum-add-value in-tx); D9 ator via `auth.uid()`). `confirm_delivery` assinatura
  **mudou** (drop 2-param antes do create; novo `p_geo_tolerance_m`). `transition_delivery`
  assinatura inalterada (`search_path` agora `public, extensions, pg_catalog`; +gate pickup
  +gate geo). `submit_proof_of_delivery` assinatura inalterada (+validação OTP). Callers
  internos preservados; GATE Sessão 10 íntegro. Hardening: reset via SQL + replay 0001→0028
  limpo (28/28); invariants 13/13, rpcs 48/48, authz 21/21, auth_lifecycle 34/34, creation
  37/37, pricing 62/62, dispatch 65/65, bid 61/61, lifecycle 67/67 (pickup POD antes de
  `picked_up`), pod_completo 40/40 PASS — **10/10 suítes, 418 asserções, sem regressão**.
  Bug de teste corrigido (C1: 2º submit reusa OTP consumido → `otp_already_used` antes de
  `pod_already_submitted`; reescrito em 3 passos). **Ressalva (regra mestra)**: Storage RLS
  comportamental + camada n8n/WhatsApp **não validados live** (Storage é API separada, não
  exercitável via curl — só estrutural; n8n #13 + envio OTP especificados em docs; live
  Sessões 14/15-16/17-19). Não simulado.
- **Sessão 13 (concluída)**: n8n — arquitetura dos workflows (design dos 16 workflows) —
  **PASS (design review)**. **Design puro** (sem migration/schema/RPC/grant novo; sem
  validação live — n8n não provisionado; não simular PASS, regra mestra). Entrega:
  ADR-018 + `N8N_WORKFLOWS.md` completo (16 workflows no template). ADR-018 (D1 n8n
  orquestrador nunca fonte da verdade — chama Route Handlers, nunca SQL/Server Actions,
  `service_role` nunca vaza ao n8n/IA, n8n nunca decide atribuição/cotação/entrega sozinho;
  D2 trigger model Realtime+reconciler sobre `delivery_events` p/ estado interno + webhook
  p/ inbound; D3 timeout n8n Wait + backstop DB — sem schema novo, `expires_at` já em 0023,
  sem pg_cron; D4 raio progressivo orquestrado pelo n8n, config em constantes/env no MVP
  — `dispatch_config` deferida p/ Sessão 26; D5 Route Handler contract surface enumerada —
  12 endpoints, os 5 system-only (`create_quote`, `open_dispatch_round`,
  `select_winner_and_claim`, `confirm_delivery`, `generate_delivery_otp`) por Route Handler
  system-scoped, `claim_delivery` interno ao SWAC sem endpoint; D6 idempotência R17 mapeada
  — `Idempotency-Key`/`external_event_id`/`external_reference`/`correlation_id` não
  misturar; D7 retry/DLQ+reconciler; D8 geocoding/routing via backend — provider atrás da
  abstração ADR-005, trust boundary do pricing; D9 n8n nunca decide atribuição — SWAC decide,
  ACEITAR ≠ GANHAR ADR-006; D10 correlation_id end-to-end + PII minimizada; D11 escopo =
  design, Sessão 14 = implementação). **Contrato verificado contra as migrations**: 23
  `delivery_event_type` (21 em 0002 + `pod_submitted` 0025 + `otp_generated` 0027), 11 RPCs
  centrais (5 system-only), assinaturas e enums conferidos — nenhuma RPC/evento inventado.
  **Decisões de usuário** (via `AskUserQuestion`): trigger Realtime+reconciler; timeout n8n
  Wait + backstop DB. **Ressalva**: implementação + validação live deferidas — Sessão 14
  (n8n) + 15-16 (WhatsApp) + 17-19 (app Next.js/Route Handlers). Risco "camada externa não
  live-validada" (Sessão 12) mantido aberto.
- **Sessão 14 (concluída — revisada, pivot n8n → API layer)**: Camada de API — Next.js
  Route Handlers (contract surface ADR-018 D5) — **PASS**. Sessão 14 como escrita
  (implementar n8n) estava BLOCKED (sem instância n8n/Route Handlers/WhatsApp; não simular
  PASS); usuário pivotou para a **camada de API** ("backend → regras → APIs"). Entrega:
  fundação Next.js 16.3.3 + 2 clients Supabase (user-scoped `@supabase/ssr` + system-scoped
  `service_role` `server-only`) + internal-auth (shared secret `x-internal-api-key`,
  timing-safe, **fail-closed**) + idempotency ledger (`integration_events`, service-only;
  `withIdempotency` claim/replay/in_flight/skip) + service layer + **9 Route Handlers
  system/internal** (`POST /api/internal/deliveries`, `/deliveries/[id]/{quote,enrich,
  confirm-quote,dispatch/rounds,confirm,otp,transitions}`, `/dispatch/rounds/[id]/close`) +
  provider abstraction (ADR-005, registry vazio → `/quote`+`/enrich` **501
  `geo_provider_not_configured`** até Sessão 20, nunca haversine p/ pricing ADR-012 D2) +
  **ADR-019** (D1 handler fino/service layer; D2 dois scopes; D3 shared secret; D4
  idempotency ledger; D5 provider 501; D6 mapeamento RPC→HTTP `ok`→200/replay→200/`reason`→
  4xx/exceção→500; D7 auth user mínima (Sessão 15); D8 logs sem secrets — OTP sensitive;
  D9 validação real não simulada) + testes unitários vitest **43/43**. `service_role` nunca
  vaza ao client/n8n/IA; n8n autentica por shared secret, handler usa system-client interno.
  `claim_delivery` interno ao SWAC (sem endpoint, GATE Sessão 10). **Validação real (dev,
  não simulada)**: regressão **10/10 suítes PASS** (418 asserções, pós reset+replay
  0001→0028, 28/28 limpo) + vertical slice via `next dev`+curl **19/19** — 401 fail-closed,
  create 200, **idempotência replay** (mesmo `Idempotency-Key` → mesmo id, 0 duplicação,
  `integration_events` gravado), 400 invalid, 501 shells, transitions 200/422,
  `wrong_state` 409, confirm-quote 200, open round 200, SWAC `no_candidates` 200 + **`won→
  assigned` 200**, **OTP 200 (6 dígitos ao caller system, ausente do log — sensitive D8)**,
  confirm id inexistente 422, **confirm `in_transit`+POD → `delivered` 200** (evento
  `delivered` actor system); estado verificado no DB via Management API. Bugs corrigidos:
  `ledger.ts` `dedupKey` snake_case (`opts.idempotency_key`→`opts.idempotencyKey`, value
  undefined quebrava o ledger) + `onConflict` fixo→dinâmico por coluna; `server-client.ts`
  import `createServerClient` colidia com fn local→alias `createSSRClient`; `result.ts`
  spread `ok` overwritten (TS2783)→reordenado. **Ressalva**: endpoints driver/user-facing
  (`respond_to_offer`, `submit_proof_of_delivery`, transitions driver-side via JWT+signed
  links) + webhook router DataCrazy + cookie/refresh/middleware full → **Sessão 15**
  (declarado, não PASS). Provider Google Maps real → **Sessão 20** (501 hoje). n8n
  implementação reabre com Route Handlers + WhatsApp.
- **Próxima**: Sessão 16 Phase 3 (restante) — sub-workflow #8-close (Wait/SWAC,
  `/dispatch/rounds/{id}/close`) + #9-nova-rodada encadeado (**bloqueado por geo 501** —
  `create_quote` precisa routing provider, Sessão 20) + envio WhatsApp real (credenciais
  Evolution/DataCrazy, D1 ADR-021 — hoje 501) + Phase 4 (docs/ADRs finais + regressão DB
  10/10 suítes). **Phase 3 sub-workflows #6/#10/#11/#12/#13/#14 + reconciler + reachability
  já provados live** (deploy Vercel público). Trigger DB `trg_delivery_events_notify_n8n` +
  dispatcher + 7 sub-workflows ativos no dev.
- **Sessão 16 (em andamento — Phase 1 + design + Phase 2 trigger model live + Phase 3
  sub-workflows provados live)**: WhatsApp outbound híbrido + n8n trigger model/contrato/live + sub-workflows provisionados. **Phase 1 (backend outbound) — PASS**: ADR-021
  (D1 provider híbrido DataCrazy+Evolution V2 [Bearer p/ conversa aberta, apikey+fallback
  flat #2570 p/ cold proactive]; D2 backend **envia+loga** via novo `POST /api/internal/
  notifications/send` [system, `x-internal-api-key`] — resolve destinatário, gera signed
  link, escolhe provider, envia, upsert em `notifications`; `service_role` interno nunca
  vaza; n8n só dispara; D3 `notifications.recipient_phone` + `whatsapp_conversations` p/
  roteamento; D5 `POST /api/internal/reconciler/scan` read-only state-based; D6 sem
  RPC/enum novo) + migration **0029** (schema prep: `notifications.recipient_phone` +
  relax CHECK + tabela `whatsapp_conversations` RLS default-deny; **sem funções**) +
  provider abstraction (copy ADR-005, 501 `whatsapp_provider_not_configured` sem provider).
  **3 bugs reais achados+fixados+provados live**: (1) `withIdempotency` **release-on-throw**
  — `fn()` que lança (provider 501/5xx) deixava claim `pending` p/ sempre → retry 409
  `in_flight`, envenenando a chave; agora `releaseClaim` deleta + propaga (lança=
  transitório, retorna RpcResult=terminal/replayable); (2) `payload NOT NULL` —
  `integration_events.payload` é NOT NULL mas endpoints `sensitive` (OTP) passavam `null`
  → insert falhava **silenciosamente** (erro em `.error`, supabase-js não lança) →
  `claimIdempotency` caía no fallback `skip` → **OTP sem idempotência**; fix `payload ?? {}`;
  (3) **OTP redact-before-record** — `recordResult` persistiria `otp_code` plaintext no
  ledger indefinidamente; agora redact antes de gravar → ledger, replay e response todos
  sem `otp_code` (ADR-021 D7). Provado live: OTP c/ `Idempotency-Key` → ledger
  `status:'processed'` `result:{ok:true,reason:'generated'}` **sem otp_code**; replay
  (mesma key) **não re-executa** (`otp_generated` +1 não +2); `delivery_otps` 1 row hash
  64. **Design/contrato (sem instância n8n)**: ADR-022 (supersede ADR-018 D2 — trigger model
  Realtime→**Database Webhooks** `pg_net`+`supabase_functions` sobre `delivery_events`
  INSERT → n8n Webhook node → Switch `record.event_type` → Execute Sub-workflow; n8n sem
  trigger nativo Realtime, DB Webhook mapeia limpo; Wait≥65s durável + reconciler backstop
  state-based; `service_role` nunca no n8n [3 fronteiras auth: Supabase→n8n
  `httpHeaderAuth` separado, n8n→backend `x-internal-api-key`, backend→Supabase
  `service_role`]; OTP: n8n chama `notifications/send {type:'otp'}`, **não**
  `/deliveries/{id}/otp` [geração-only, redact]; reconciler `reconciler/scan`; inbound
  backend router [#1/#7/#16]) + `N8N_WORKFLOWS.md` revisado (tabela de endpoints alinhada
  Sessões 14-15 [/api/driver/deliveries/{id}/{transitions,pod}, /api/internal/
  notifications/send, /reconciler/scan, /offers/{id}/respond-link, /api/offers/{id}/respond
  dual cookie-ou-token], #6/#10/#11/#12 → `notifications/send`, #8 reason
  `already_assigned` [não `superseded_by_concurrent_claim` — este é metadata.reason do
  `round_closed`], #15 → `reconciler/scan` state-based, #1/#7/#16 = backend router).
  **Phase 2 (trigger model) — PASS live (não simulado)**: usuário provisionou instância n8n
  (`https://n8n.processlabcorp.com.br/`) + Public API key. (1) **pg_net egress** dev Supabase
  → n8n público provado (echo workflow + exec 209392, body `{"hello":"from-pgnet"}` no
  runData, `user-agent: pg_net/0.20.4`). (2) **Dispatcher `VIO10-dispatcher`**
  (id `8M68aj7oExxijS73`): Webhook → Code valida `x-webhook-secret` (reject
  `invalid_webhook_secret`, exec 209410) + mapeia `event_type`→workflow; ping manual → exec
  209409 `success` route `delivery_created→#2-enrich`. (3) **DB trigger**
  `trg_delivery_events_notify_n8n` (AFTER INSERT `delivery_events`, função
  `notify_n8n_delivery_event` SECURITY DEFINER `net.http_post` ao dispatcher c/
  `x-webhook-secret`) — **infra de runtime, NÃO migration** (ADR-022 D1: provisão live via
  Management). Provado: INSERT real → trigger dispara → n8n exec c/ `event_id` batendo
  exato: `delivery_created`→#2 (209417), `delivered`→#12 (209419), `otp_generated`→NOOP-chain
  (209420), `round_closed`→#8 (209421). (4) **Sub-workflow `VIO10-#2-enrich`**
  (id `zQsbwxwW9I8wD32L`): HTTP Request → `http://localhost:3000/.../{id}/enrich` c/ headers
  `x-internal-api-key` + `Idempotency-Key:{corr}-enrich` — exec 209427 montou o request
  (wiring provado) + errou `ECONNREFUSED` = **gap honesto de reachability** (n8n público →
  backend localhost; tunnel/prod; handlers já provados via curl Sessão 14-15). `service_role`
  nunca no n8n (3 fronteiras auth); OTP plaintext nunca transita n8n (D5).
  Hardening: `tsc` limpo; **175/175 vitest** (16 suítes, +2 regressões ledger). **Phase 3
  (sub-workflows provados live — não simulado)**: deploy Vercel público
  `https://vio10-frete.vercel.app` resolveu reachability (sem ECONNREFUSED — n8n público →
  backend público). **8 fluxos backend provados end-to-end c/ chave real** (chave colada pelo
  usuário em cada workflow): #2-enrich→501 geo, #6-offer→501 whatsapp, #10-assign→501, #11-update→501
  (**+branch `in_transit`→otp** via Code "Build items" que emite 2 items p/ in_transit —
  status_update+otp; 1 item p/ outros; backend `type:'otp'` → generate_delivery_otp interno,
  otp_code não vaza ADR-022 D5), #12-notify→501, #13-confirm→422 pod_required, #14-failure→not_found,
  #15-reconciler→200 scan. Dispatcher mapeia 7 webhook URLs (`in_transit` unificado → #11;
  `round_closed`/`otp_generated`→NOOP — fix do loop latente #8). **3 bugs reais do n8n
  httpRequest v4.2 achados+corrigidos+provados live**: (a) objeto literal aninhado
  (`{metadata:{reason}}` em `JSON.stringify`) → `invalid syntax` → fix `JSON.parse('...')`
  como valor; (b) delimitador `{{ }}` colide c/ `}}` no JSON string → `invalid syntax` →
  mesmo fix; (c) **campo `url` c/ `{{ }}` inline NÃO resolve** → passa literal como path
  param `[id]` → backend 500 `internal_error` (mascarado por 401 antes da chave real) → fix
  URL em modo expressão `={{ '...'+$json.body.delivery_request_id+'/...' }}`. Lições gravadas
  em `memory/n8n-live-infra.md` (#8-#11). `service_role` nunca no n8n (3 fronteiras auth);
  OTP plaintext nunca transita n8n (D5). **Ressalva (regra mestra)**: #8-close + #9-nova-rodada
  (bloqueado por geo 501 — `create_quote` precisa routing provider Sessão 20) + envio WhatsApp
  real (credenciais Evolution/DataCrazy, ADR-021 D1 — hoje 501) + Phase 4 (docs/ADRs finais
  + regressão DB 10/10 suítes — vitest 175/175 reconfirmado sem regressão). Geo 501 (Sessão
  20). Storage RLS, UI, rate limiting/mTLS → Sessões 17-19/22/26.
- **Sessão 15 (concluída)**: Endpoints driver/user-facing, signed links, webhook router,
  cookie/middleware full — **PASS (com ressalva)**. Camada de aplicação **pura** —
  **sem migration/RPC/enum/grant novo** (os 4 RPCs driver-facing — `respond_to_offer` (0016),
  `submit_proof_of_delivery` (0028), `transition_delivery` (0028), `set_driver_availability`
  (0016) — são finais desde Sessões 09-12). Entrega: signed links HMAC (`lib/auth/signed-link.ts`,
  fail-closed, IDOR `o===offerId`, TTL 900s, timing-safe) + handlers (`handleUserPost` cookie
  JWT→401, `handleOfferRespondPost` dual-auth cookie-ou-token, `handleWebhookPost`
  signature→dedup `webhook_events`→route→200 sempre, `verifyDatacrazySignature` timing-safe
  fail-closed) + service layer driver (`respondToOffer`/`submitProofOfDelivery`/
  `transitionDeliveryDriver`/`setDriverAvailability` void+raise→403, `resolveDriverId` de
  `auth.uid()`) + validators + **6 Route Handlers** (`POST /api/offers/{id}/respond` dual,
  `/api/driver/deliveries/{id}/{transitions,pod}`, `/api/driver/availability`,
  `/api/internal/offers/{id}/respond-link` generator, `/api/webhooks/datacrazy`) + login
  placeholder + `lib/supabase/middleware-client.ts` (SEM server-only) + `middleware.ts`
  reescrito (`getUser()` refresh `setAll`→response.cookies, protege `/driver`/`/admin`/
  `/business`→307 `/auth/login` — `NextResponse.redirect` default, validado live) + `reasonToStatus` estendido (`unauthenticated`→401,
  `offer_expired`→410, `offer_already_responded`/`invalid_transition`/...→409,
  `offer_not_found_for_driver`→404, `invalid_bid_amount`/`invalid_pod`→400, `not_authorized`→403)
  + **ADR-020** (D1 dois modos auth; D2 service aceita client; D3 signed link HMAC; D4
  generator system sem ledger; D5 webhook router signature+dedup+route+200; D6
  cookie/middleware full; D7 idempotência interna respond_to_offer sem ledger; D8 mapeamento
  estendido; D9 logs sem secrets; D10 sem migration) + BACKEND §11 + ARCHITECTURE §15 +
  `.env.example` (`ACTION_LINK_SIGNING_SECRET`, `DATACRAZY_WEBHOOK_SECRET`,
  `NEXT_PUBLIC_APP_URL`). `service_role` nunca vaza (signed link system-scoped só p/
  respond_to_offer; webhook só `webhook_events` service-only + services; user-facing user-scoped).
  ACEITAR ≠ GANHAR + Submete POD ≠ entregue preservados. Hardening: `tsc --noEmit` clean;
  **124/124** vitest PASS (12 suítes, 81 novos); regressão DB **10/10 suítes** (zero
  regressão, nada tocou o DB) + **live vertical slice `next dev`+curl (dev, real)**:
  cookie JWT (availability on/off/restore → 200, sem cookie → 401; transitions
  assigned→driver_to_pickup→at_pickup→picked_up→in_transit → 200; POD pickup → 200 +
  `pod_submitted`), signed link (generator internal-auth → `{token,url}`; respond
  system-scoped → `accepted`+bid; tampered/expired/IDOR → 401; replay →
  `already_responded`), webhook (signature válida → 200+`accepted`; duplicado →
  `idempotent_replay`; sig inválida → 401; unknown intent → `routed_with_error`;
  `otp_request` → OTP gerado+evento), SWAC `select_winner_and_claim` → `assigned`
  (1 assignment ativa), middleware (sem cookie → **307** `/auth/login?redirect=`;
  com cookie → passa). **Achado live**: location do driver envelheceu >300s durante o
  setup → SWAC corretamente `no_candidates` (round fecha) → recovery reproduziu o
  caminho fiel de produção (nova rodada c/ location fresca) → 9/9 PASS. **Bug de
  harness, não de código.** Bugs de código corrigidos:
  `webhook-handler` `createSystemClient()` row-type `never` (ReturnType mais estrito que
  `SupabaseClient<any>`)→anotado `SupabaseClient`; `vi.fn` sem params→tipados.
  **Ressalva (regra mestra — não simulado PASS)**: UI PWA/dashboards/portal (Sessões 17-19),
  WhatsApp outbound real (Sessão 16), provider Google Maps (Sessão 20 — `/quote`+`/enrich`
  501), Storage RLS comportamental (Sessões 17-19), rate limiting/mTLS/rotação (Sessão 22/26),
  n8n implementação live (Sessão 16 + reabertura n8n).

Ver `PLAN.md` para o roadmap completo e `CHANGELOG.md` para o histórico.

<!-- BEGIN:nextjs-agent-rules -->

# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` (resolved from this file's directory; in monorepos the `next` package may not be visible from the repo root) before writing any code. Heed deprecation notices.

This block is written and re-added by `next dev` — verify at `node_modules/next/dist/server/lib/generate-agent-files.js`. Removing it from a diff only re-creates the uncommitted change; committing it with your work keeps the tree clean.

<!-- END:nextjs-agent-rules -->
