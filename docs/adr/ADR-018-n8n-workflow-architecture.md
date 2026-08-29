# ADR-018 — Arquitetura dos workflows n8n (design dos 16 workflows)

- **Status**: Aprovado
- **Data**: 2026-08-28
- **Sessão**: 13

## Contexto

A Sessão 12 (ADR-017) fechou a **camada DB completa** (28 migrations, 10/10 suítes PASS,
418 asserções) e **especificou** a camada externa n8n/WhatsApp (workflow #13 entrega
concluída + envio de OTP via DataCrazy), marcando validação live como **deferida** (sem
simular PASS — regra mestra). A Sessão 13 é a **sessão de arquitetura** do n8n: o design
completo dos 16 workflows. A **Sessão 14** é a implementação (n8n provisionado). A Sessão 13
**não tem código de banco** nem validação live — é **design puro** (docs + ADR-018).

### O que existe hoje no repositório

`supabase/` (28 migrations, RPCs validados real no dev) + `docs/` (mãe + ADR-001 a ADR-017).
**Não há camada de aplicação**: sem Next.js, sem n8n instância, sem WhatsApp. O que existe é
o **contrato** — a superfície que o n8n deve orquestrar sem virar fonte da verdade:

- **11 RPCs centrais** (5 system-only): `create_delivery_request`, `create_quote`,
  `confirm_quote`, `open_dispatch_round`, `select_winner_and_claim`, `respond_to_offer`,
  `transition_delivery`, `submit_proof_of_delivery`, `confirm_delivery`,
  `generate_delivery_otp`, `claim_delivery` (interno ao SWAC, nunca chamado direto).
- **23 valores de `delivery_event_type`**: 21 em 0002 + `pod_submitted` (0025) +
  `otp_generated` (0027). Esta é a **superfície de trigger** do Realtime.
- **3 campos de idempotência** distintos (R17): `idempotency_key` (retry dedup),
  `external_reference` (criação dedup, UNIQUE por `organization_id` em `delivery_requests`),
  `external_event_id` (`webhook_events.external_id`, inbound reprocessado).
- **Fronteira DataCrazy** (Fase 8, Sessões 15-16): mensageria + IA conversacional; nunca
  escreve no banco, chama o backend.
- **Loop de raio progressivo** (ADR-013 D5): orquestrado pelo n8n, **não** no RPC —
  `open_dispatch_round` abre **uma** rodada por chamada; o orquestrador fecha a anterior
  (via SWAC) antes de abrir a próxima.
- **POD/OTP two-phase** (ADR-017): `submit_proof_of_delivery` (driver-scoped, valida OTP
  com `for update`, não transita) ≠ `delivered`; `confirm_delivery` (system-only)
  confirma via `transition_delivery('delivered')` re-validando gates.
- **GATE de produção da Sessão 10**: atribuição atômica em concorrência real validada;
  `claim_delivery` é interno ao `select_winner_and_claim` — n8n nunca o chama direto.

### Tensões de escopo (resolvidas com o usuário no planejamento)

Duas decisões arquiteturais não deriváveis dos ADRs existentes foram confirmadas via
`AskUserQuestion` antes de fechar o design:

1. **Modelo de trigger.** Opções: (a) polling do DB periódico, (b) Realtime sobre
   `delivery_events`, (c) Realtime + reconciler. O usuário escolheu **(c) Realtime +
   reconciler** — Realtime como gatilho primário dos workflows de estado interno, com um
   workflow reconciler periódico capturando o que o Realtime perdeu (n8n down/restart).
   Honra "Banco é a fonte da verdade" (eventos já vivem em `delivery_events`). Inbound
   (DataCrazy/motorista) continua webhook — eles não falam Realtime.
2. **Timeout da rodada.** Opções: (a) timer puramente no n8n (Wait node), (b) timer no
   banco (pg_cron/trigger), (c) n8n Wait primário + backstop DB. O usuário escolheu **(c)
   n8n Wait + backstop DB** — n8n agenda o Wait, um reconciler fecha rodadas com
   `expires_at < now()` e `status='open'` que o Wait perdeu. **Sem schema novo**
   (`expires_at` já existe em 0023); sem pg_cron (não acopla o banco a disparar orquestração).

## Decisões

### D1 — n8n é orquestrador, nunca fonte da verdade

Codifica a **regra mestra** ("Banco é a fonte da verdade. Backend decide. n8n orquestra"):

- n8n chama **Route Handlers** do backend — **nunca** SQL/DB direto, **nunca** Server
  Actions internas (Server Actions são só para ações originadas no próprio frontend,
  `FRONTEND.md`).
- O **backend decide** por operação se roda user-scoped (JWT, RLS) ou system-scoped
  (`service_role`, RLS bypass). **`service_role` nunca vaza ao n8n/DataCrazy/IA** — eles
  chamam endpoints; o backend escolhe o contexto internamente.
- n8n **nunca decide sozinho** atribuição, cotação, ETA, entregador ou status (regra
  mestra: "IA não inventa preço, ETA, entregador ou status"). n8n **pede** a operação e o
  backend **retorna** o resultado (`won`/`lost`/`quoted`/`delivered`/reason).
- n8n **não depende de Server Actions internas** (`CLAUDE.md` camadas e fronteiras).

### D2 — Trigger model: Realtime + reconciler (estado interno); webhook (inbound)

- **Workflows de estado interno** (#3 cotação, #4 início dispatch, #11 atualizações, #13
  entrega): **Supabase Realtime** sobre `delivery_events`, filtrado por `event_type`. O
  DB é a fonte da verdade; eventos já são auditados em `delivery_events` (imutável).
- **Reconciler** (workflow periódico, parte de #15): varre
  (a) `delivery_events` não-processados (n8n esteve down — reprocessa o workflow
  correspondente); (b) estados presos — drafts sem quote → #3, `searching_driver` sem
  rodada aberta e `round_count < max` → #5/#9, rodadas `open` com `expires_at < now()` →
  #8. Idempotente via `external_event_id` + estado da corrida (D6).
- **Inbound** (#1 nova solicitação, #7 resposta do motorista, #16 webhooks DataCrazy):
  **webhook HTTP** — DataCrazy/motorista não falam Realtime. Dedup via
  `webhook_events.external_id`.

### D3 — Timeout da rodada: n8n Wait + backstop DB

- **Primário**: n8n agenda um **Wait node** `response_window_seconds` após #5 abrir a
  rodada; ao expirar dispara #8 (close → SWAC).
- **Backstop**: reconciler periódico (D2) fecha rodadas com `expires_at < now()` e
  `status='open'` que o Wait perdeu (n8n crash/restart).
- **Sem schema novo** — `expires_at` já existe em `dispatch_rounds` (0023).
- **Sem pg_cron/trigger** — não acopla o banco a disparar orquestração; mantém "n8n
  orquestra, banco é verdade". O reconciler é um **workflow n8n**, não infra de DB.

### D4 — Raio progressivo orquestrado pelo n8n; config em constantes/env no MVP

- O loop (#5 abrir → #6 enviar → #8 timeout/close → #9 no_candidates → #5 próxima rodada)
  é do **n8n**, não do RPC (ADR-013 D5).
- A sequência de raios / `max_candidates` / `driver_offer_cents` / `response_window_seconds`
  vem de **constantes/env do n8n** no MVP (tabela `dispatch_config` deferida — ADR-013).
  Kill switches/limites (max rounds, raio máx) ficam no config do n8n; **Sessão 26**
  endurece em DB.
- `open_dispatch_round` abre **uma** rodada por chamada; o guard `round_already_open`
  protege sobreposição; o orquestrador **fecha** a rodada anterior (via SWAC em #8) antes
  de abrir a próxima.
- Exaustão (max_rounds) → `transition_delivery('expired')` (system) — terminal (#14).

### D5 — Route Handler contract surface (enumerada)

n8n chama estes endpoints; o backend mapeia cada um à RPC com o escopo correto. O app
Next.js **não existe** (Sessões 17-19) — o contrato é **especificado** agora; implementação
em Sessão 14/17-19.

| Endpoint | Escopo | RPC | Workflows |
|---|---|---|---|
| `POST /api/internal/deliveries` | system (`origin=whatsapp\|integration`) | `create_delivery_request` | #1 |
| `POST /api/internal/deliveries/{id}/enrich` | system | `GeocodingProvider.geocode` + validação + persistência | #2 |
| `POST /api/internal/deliveries/{id}/quote` | system | `RoutingProvider.route` + `create_quote` | #3 |
| `POST /api/internal/deliveries/{id}/confirm-quote` | user JWT **ou** system | `confirm_quote` | #4 (dashboard) |
| `POST /api/internal/deliveries/{id}/dispatch/rounds` | system | `open_dispatch_round` | #5, #9 |
| `POST /api/internal/dispatch/rounds/{id}/close` | system | `select_winner_and_claim` | #8 |
| `POST /api/offers/{id}/respond` | driver (signed link → user JWT) | `respond_to_offer` | #7 |
| `POST /api/internal/deliveries/{id}/transitions` | driver/admin/system (matriz ADR-016) | `transition_delivery` | #11 (driver), #14 (system) |
| `POST /api/internal/deliveries/{id}/pod` | driver | `submit_proof_of_delivery` | trigger #13 |
| `POST /api/internal/deliveries/{id}/confirm` | system | `confirm_delivery` | #13 |
| `POST /api/internal/deliveries/{id}/otp` | system | `generate_delivery_otp` | OTP-send (#11) |
| `POST /api/webhooks/datacrazy` | público c/ signature | router inbound | #16 |

Os **5 system-only** (`create_quote`, `open_dispatch_round`, `select_winner_and_claim`,
`confirm_delivery`, `generate_delivery_otp`) vão por Route Handlers **system-scoped**
(Service Role interno) — **nunca** expostos ao n8n/IA direto. `claim_delivery` é interno ao
SWAC (GATE Sessão 10) — sem endpoint próprio.

### D6 — Idempotência mapeada (R17 — não misturar)

- **`Idempotency-Key`** header → `integration_events.idempotency_key` → **dedup de retry**
  (mesma call re-executada pelo n8n/Backoff). Backend retorna o resultado original.
- **`external_event_id`** → `webhook_events.external_id` / `integration_events` → **dedup
  de webhook/event inbound reprocessado** (emissor reenvia o mesmo evento).
- **`external_reference`** → `delivery_requests` UNIQUE por `organization_id` → **dedup de
  criação** (duas corridas para o mesmo pedido externo).
- **`respond_to_offer`**: uma resposta válida por (offer, driver); duplicata retorna o
  resultado original. Usa `p_idempotency_key`.
- Toda call mutante carrega **`correlation_id`** (propagação end-to-end, **não** é dedup).

### D7 — Retry/DLQ: backoff exponencial + dead-letter + reconciler

- Retries são **normais** (não erros): backoff exponencial (max N, ex.: 3-5).
- Após N → **dead-letter queue** + alerta (workflow #12). DLQ exige intervenção humana.
- O reconciler (D2) reprocessa Realtime perdido; a idempotência (D6) garante que
  retry/reprocess **não duplique efeito**.

### D8 — Geocoding/routing = providers, chamados pelo backend (Route Handler/application)

- n8n **não** chama Google Maps direto; n8n chama o Route Handler (`/enrich`, `/quote`) que
  invoca o `GeocodingProvider`/`RoutingProvider` atrás da abstração (ADR-005, Sessão 20).
- **Trust boundary do pricing**: distância/duração vêm do **provider** (plataforma),
  **nunca** do business — `create_quote` é system-only (ADR-012 D1). IA não geocodifica
  nem roteiriza.
- *Sequenciamento (detalhe aberto p/ Sessão 14/20)*: o geocode inicial (address→coords)
  para satisfazer `pickup_point`/`delivery_point` NOT NULL acontece no Route Handler de
  create (#1) antes da RPC; #2 é enriquecimento/validação (reverse-geocode, snap-to-road,
  qualidade de endereço); #3 é rota (distance/duration) + `create_quote`. Se 0021 aceitar
  coords vs address diferir, ajusta-se o Route Handler, **não** o design do workflow.

### D9 — n8n nunca decide atribuição; SWAC decide

- `select_winner_and_claim` (system-only, ADR-014) pontua + chama `claim_delivery`
  atomicamente na mesma transação (GATE Sessão 10).
- n8n só pede o close (#8); o resultado (`won` / `no_candidates` /
  `superseded_by_concurrent_claim`) vem do SWAC.
- **ACEITAR ≠ GANHAR** (ADR-006): o motorista ACEITA via #7 (`respond_to_offer`, não
  atribui); o **sistema** escolhe no close. n8n não chama `claim_delivery` direto.

### D10 — correlation_id end-to-end; logs sem secrets, PII minimizada

- `correlation_id` propagado **DataCrazy → n8n → backend** em toda call.
- Logs: `correlation_id`, `delivery_request_id`, `organization_id`, origem, resultado.
- **Nunca** secrets nem PII desnecessária: telefone do recebedor só no envio do OTP; não
  logar plaintext do OTP (o código só existe em `generate_delivery_otp` → DataCrazy →
  recebedor; no banco só o hash).

### D11 — Escopo Sessão 13 = design (docs + ADR-018); Sessão 14 = implementação

- **Sem migration/schema/RPC/grant novo.**
- **Sem validação live** — n8n/WhatsApp não provisionados; não simular PASS (regra mestra).
- Entrega: ADR-018 + `N8N_WORKFLOWS.md` completo (16 workflows no template "para cada
  workflow") + index/CHANGELOG/CODE_REVIEW/PLAN/CLAUDE.
- Veredito GO → **Sessão 14** (implementação dos workflows em instância n8n provisionada).

## Consequências

- O n8n fica confinado a orquestrar contratos já validados — nenhum poder de decisão
  sobre estado crítico; a regra mestra é estruturalmente respeitada.
- O modelo Realtime+reconciler torna o sistema **resiliente a restarts do n8n** sem perder
  eventos (reconciler reprocessa) — à custa de um workflow periódico extra.
- O timeout com backstop DB elimina a necessidade de schema novo (sem pg_cron) — a
  infraestrutura de orquestração fica no n8n, onde pertence.
- A `Route Handler contract surface` (D5) torna-se o **contrato de implementação** para as
  Sessões 14 (n8n) e 17-19 (Next.js Route Handlers) — ambas as camadas consomem o mesmo
  endpoint.
- Dívida técnica observada: config de dispatch em constantes do n8n (não DB) —
  endurecido em Sessão 26.
- Risco "camada externa não live-validada" (Sessão 12) **mantido aberto** — Sessão 13 é
  design; a validação live da orquestração+n8n+WhatsApp é Sessão 14/15-16.

## Referências

- Regra mestra — `CLAUDE.md`.
- n8n orquestrador, fronteira — `ARCHITECTURE.md`, `BACKEND.md`, `CLAUDE.md` camadas.
- ADR-005 (abstração de provider), ADR-006 (ACEITAR ≠ GANHAR), ADR-012 (pricing
  system-only), ADR-013 (dispatch + raio progressivo), ADR-014 (SWAC), ADR-015 (atribuição
  atômica), ADR-016 (matriz ator×transição), ADR-017 (POD/OTP two-phase).
- R17 (idempotência — três campos) — `docs/DECISIONS.md`.
- Design dos 16 workflows — `docs/N8N_WORKFLOWS.md`.