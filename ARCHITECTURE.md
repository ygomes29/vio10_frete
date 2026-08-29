# ARCHITECTURE.md — Arquitetura do ViO10

## 1. Regra mestra

> **Banco é a fonte da verdade. Backend decide. n8n orquestra. IA interpreta.
> DataCrazy comunica. Frontend apresenta e coleta ações.**

Nenhuma camada externa altera diretamente estado operacional/financeiro crítico. O
Postgres (via Supabase) é a autoridade final de estado. O backend é a única camada
que escreve estado, e mesmo as transições críticas passam por funções RPC transacionais.

## 2. Stack

| Camada | Tecnologia |
|---|---|
| Frontend (3 superfícies) | Next.js 16.3.3 (App Router, TS, Tailwind, shadcn/ui) |
| Backend (API + serviços) | Next.js Route Handlers + camada de domínio/serviço |
| Atomicidade / estado crítico | Funções RPC do Postgres (Supabase) |
| Banco / Auth / Storage / Realtime | Supabase (PostgreSQL) |
| Orquestração | n8n self-hosted |
| Mensageria / IA conversacional | DataCrazy (Crazy IA) + WhatsApp Cloud API |
| Geolocalização | Google Maps Platform atrás de abstração de provider |

## 3. Camadas e fronteiras

```
┌─────────────────────────────────────────────────────────┐
│  UI (React/Next) — 3 route groups: (driver)(admin)(business) │
│                apenas apresenta estado oficial e coleta ações  │
└──────────────────────────┬──────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────┐
│  Application / Service  — orquestra casos de uso, autoriza │
└──────────────────────────┬──────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────┐
│  Domain  — regras de negócio determinísticas (pricing,     │
│            scoring, máquina de estados, eligibility)      │
└──────────────────────────┬──────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────┐
│  Persistence / RPC (Postgres) — FONTE DA VERDADE            │
│  constraints, RLS, funções atômicas (claim_delivery,        │
│  transition_delivery), auditoria (delivery_events)         │
└──────────────────────────────────────────────────────────┘
```

Fronteiras de escrita:

- **Frontend** → chama API do backend (Route Handlers) ou Server Actions (somente
  ações originadas no próprio frontend). Nunca escreve estado direto.
- **n8n** → chama endpoints do backend (Route Handlers), idempotentes. O backend
  responde "venceu/perdeu". **Não** depende de Server Actions. **Não** escreve no banco.
- **DataCrazy / IA** → dispara webhooks (via n8n ou direto ao backend) com payload
  estruturado. **Nunca** SQL/banco direto. **Nunca** decide preço/ETA/status.
- **Backend** → única camada que escreve estado; transições críticas via RPC.

### 3.1 Contextos de execução no backend — `service_role` user-scoped vs system-scoped

O backend acessa o Postgres em **dois contextos distintos**, com roles e semântica
diferentes. Confundi-los é o erro arquitetural mais perigoso do stack (permite que um
usuário aja como sistema, ou que o sistema vaze dados cross-tenant).

| Contexto | Role | RLS | Quem dispara | Quando usar |
|---|---|---|---|---|
| **User-scoped** | `authenticated` (JWT do usuário) | **Aplica** (filtra por `organization_id`/driver) | Frontend (ação de um usuário autenticado), webhook de entregador | Toda operação feita **em nome de** um usuário: motorista aceita offer, business cria corrida, admin consulta. O backend valida autorização daquele usuário e o RLS still filtra como defesa em profundidade. |
| **System-scoped** | `service_role` | **Bypass** (rolbypassrls) | Apenas código **interno e confiável** do backend: dispatch engine, scoring, `claim_delivery`, expiração scheduled, transições de sistema | Toda operação **do próprio sistema** que não pertence a nenhum usuário: abrir rodadas de dispatch, pontuar candidatos, atribuir vencedor, fechar rodadas expiradas, eventos de auditoria de sistema. |

**Regras de ouro:**

1. **`service_role` nunca vaza para fora do backend.** n8n, DataCrazy, IA e qualquer
   integrador externo **não** recebem a chave `service_role`. Eles chamam endpoints do
   backend; o backend decide, por operação, em qual contexto executar.
2. **Uma operação iniciada por um usuário roda user-scoped** (JWT do usuário, RLS
   aplica). O backend **não** "promove" uma ação de usuário a system-scoped para
   bypassar RLS — isso seria um buraco de autorização. Se o usuário não teria direito
   via RLS, o backend também não deve conceder.
3. **Ações de sistema são determinísticas e confiáveis** (lógica do backend, não
   input de usuário). Elas rodam system-scoped porque representam a plataforma, não um
   tenant. Ainda assim, escrevem via RPCs transacionais (`claim_delivery`,
   `transition_delivery`) — nunca SQL ad-hoc que ignore a máquina de estados.
4. **RPCs user-facing são `SECURITY DEFINER` com checagem interna de `auth.uid()`**
   (Modelo B, Sessão 04 — reverte a decisão INVOKER da Sessão 03; ver ADR-009 e
   `0016_rpcs_security_definer.sql`). A RPC roda como **owner** (postgres, bypassa
   RLS) e valida posse/role do caller **internamente** lendo `auth.uid()` do JWT:
   `auth.uid() IS NULL` → chamada system-scoped (service_role/owner), permitida;
   `auth.uid() IS NOT NULL` → chamada user-scoped, valida `drivers.user_id = auth.uid()`
   (motorista), membership da org (business) ou `user_platform_roles` (admin/operator).
   **Por que não INVOKER:** com INVOKER as mutações internas da RPC rodariam como o
   caller `authenticated`, exigindo grants de DML a `authenticated` — o que abre bypass da
   máquina de estados via PostgREST direto (ex.: `PATCH delivery_requests.status` sem
   passar por `transition_delivery`). Com DEFINER + sem grants de DML a `authenticated`,
   a única forma de mutar estado é a RPC, que faz a checagem. `auth.uid()` funciona sob
   DEFINER (lê o JWT, não o role do DB).
5. **Grants são least-privilege desde a Sessão 04** (`0014` default-deny total +
   `0015` least-privilege): `service_role` (system-scoped) recebe DML em todas as
   tabelas + EXECUTE nas 4 RPCs; `authenticated` (user-scoped) recebe SELECT em 20
   tabelas (sob RLS — `0017`) + EXECUTE nas 3 RPCs user-facing + INSERT/UPDATE só em
   `driver_locations` (telemetria, sem regra a bypassar); `anon` nada. Nenhum DML de
   domínio a `authenticated` — mutação user-face só via RPC DEFINER.

## 4. Fluxo de dados (caminho feliz)

```
empresa (Portal ou WhatsApp)
  → cria delivery_request (draft)
  → PRICING ENGINE determinístico → delivery_quote (quoted)
  → empresa confirma → status = searching_driver
  → n8n: cria dispatch_round #1 (raio menor) → delivery_offers a N entregadores
  → DataCrazy envia oferta via WhatsApp (link assinado + expirável)
  → entregador responde ACCEPT / COUNTER_BID / DECLINE → POST no backend (idempotente)
       (ACEITAR = lance igual a driver_offer_cents; NÃO ganha imediatamente)
  → rodada fecha após janela configurada
  → BID ENGINE: ranking determinístico → candidato vencedor
  → claim_delivery() RPC ATÔMICO (constraint + FOR UPDATE) → vencedor oficial
  → status = assigned → delivery_event → notifica participantes
  → ciclo de entrega (máquina de estados) → proof of delivery → delivered
```

## 5. Tenancy

`organization` (tenant, limite de RLS) → `business` → `business_location`.
Toda tabela de domínio carrega `organization_id` e é protegida por RLS. Detalhes em
`docs/PRODUCT.md` e `BACKEND.md`.

## 6. Atribuição atômica (ponto de maior risco)

1. **Constraint parcial** em `delivery_assignments`:
   `UNIQUE (delivery_request_id) WHERE status = 'active'` — o banco fisicamente
   impede duas atribuições ativas.
2. **RPC `claim_delivery(p_request_id, p_driver_id, p_offer_id)`**: `BEGIN;
   SELECT … FOR UPDATE` na `delivery_requests`; valida `status = searching_driver`
   e offer válida; `INSERT` assignment + `UPDATE` status + `INSERT` delivery_event
   numa transação; `COMMIT`. Retorna `{won: true}` ou `{won: false, reason}`.
3. Respostas atrasadas/retries/webhooks repetidos batem na constraint/lock → retornam
   `already_assigned`. Sem dependência de timing do n8n.

Mesmo após o Bid Engine escolher o candidato, ele **não** é vencedor oficial até
`claim_delivery()` confirmar atomicamente. Detalhes em `docs/BID_ENGINE.md` e
`BACKEND.md`.

## 7. Estados da corrida

`draft → quoted → searching_driver → assigned → driver_to_pickup → at_pickup →
picked_up → in_transit → delivered` (+ `cancelled`, `failed`, `expired`).

`bidding` **não** é estado principal; a disputa vive dentro de `searching_driver` via
`dispatch_rounds`/`delivery_offers`/`bids`. Toda transição crítica passa por
`transition_delivery()` RPC. Detalhes em `docs/DELIVERY_LIFECYCLE.md`.

## 8. Dinheiro

Valores em inteiros (centavos): `customer_price_cents`, `driver_offer_cents`,
`driver_earning_cents`, `platform_fee_cents`, `bid_amount_cents`. Currency `BRL`.
Nunca float para finança.

## 9. Idempotência

- `webhook_events` / `integration_events` com `(source, external_id)` UNIQUE.
- `idempotency_key` em endpoints mutantes. `external_event_id` por evento.
- Retries são parte normal da arquitetura. Detalhes em `docs/SECURITY.md` e
  `BACKEND.md`.

## 10. Observabilidade

Eventos críticos carregam: `correlation_id`, `organization_id`, `delivery_request_id`,
`actor`, `timestamp`, `event_type`, `origem`, `resultado`, `erro`. Não construímos
infra completa agora, mas a arquitetura não pode ser opaca. `delivery_events` é a
trilha de auditoria da corrida.

## 11. Geolocalização

Provider inicial: Google Maps Platform (geocoding + Routes API com `TWO_WHEELER`).
Acesso exclusivo via abstração `GeocodingProvider` / `RoutingProvider`. O domínio
nunca chama Google diretamente. Localização do entregador tem conceito de `stale`
(nunca tratar coordenada antiga como atual). Detalhes em `docs/GEOLOCATION.md`.

## 12. Limites do MVP (anti over-engineering)

- Operar só em Congonhas/MG.
- Sem surge pricing complexo.
- Scoring usa só dados disponíveis (valor, ETA, distância); rating/completion-rate
  ficam no modelo mas ponderados a 0 até haver histórico.
- Multiempresa/multicidade: **preparado**, não construído.
- Tracking em background: não presumir; PWA em foreground (~10s). App nativo só se
  justificar no futuro.

## 13. Estado da implementação do banco (Sessão 03)

13 migrations em `supabase/migrations/` (ver `CHANGELOG.md`). Destaques:

- **PostGIS** habilitado: `geography(Point,4326)` em `driver_locations`,
  `service_areas`, `business_locations`, `delivery_requests.pickup_point`/
  `delivery_point`, `proof_of_delivery.location_point`; índices GiST. Pré-filtro
  de candidatos por `ST_DWithin`; Google Maps só no subconjunto (Sessão 20).
- **Tenancy duplo escopo** (sem organization fictícia): `user_platform_roles`
  (super_admin/admin/operator — platform-scoped); `organization_memberships`
  (business_owner/business_user — org-scoped). `drivers` são platform-scoped
  (sem `organization_id`).
- **Dinheiro**: `BIGINT` `*_cents` (BRL).
- **Atomicidade**: `claim_delivery()` RPC + partial unique index
  `delivery_assignments(delivery_request_id) WHERE status='active'`.
- **Bid/offer coerência**: FK composto `bids → delivery_offers(id, driver_id)`.
- **Auditoria**: `delivery_events` imutável (trigger bloqueia update/delete).
- **RLS**: habilitado em todas as tabelas, default deny. Políticas na Sessão 04.
- **Financeiro** (payments/payouts/ledger): adiado à Sessão 21.

## 14. Camada de API — Route Handlers Next.js (Sessão 14, ADR-019)

A **contract surface** do ADR-018 D5 (12 endpoints → 11 RPCs) é realizada em código pela
camada de API Next.js 16.3.3 (App Router). Os RPCs `SECURITY DEFINER` (Sessões 03-12)
permanecem a fonte da verdade; os Route Handlers são **HTTP wrappers finos** (BACKEND §10).

- **Dois clients, dois scopes**: `createServerClient()` (user-scoped, cookie→JWT→`auth.uid()`,
  RLS aplica) para usuário/driver; `createSystemClient()` (`service_role`, `server-only`, RLS
  bypass, `auth.uid()` null) para os 5 system-only + ledger. **`service_role` nunca vaza** ao
  client/n8n/IA.
- **System-callers (n8n) autenticam por `x-internal-api-key`** (shared secret, timing-safe,
  fail-closed) — nunca por `service_role`. Verificado → handler usa system-client interno.
- **Idempotency ledger** (`integration_events`, service-only): `withIdempotency` claima antes
  da RPC mutante; replay retorna o resultado cacheado sem re-executar; `in_flight` → 409.
  `Idempotency-Key`→retry dedup; `external_event_id`→inbound dedup; `correlation_id`→só log
  (R17 — não misturar).
- **Mapeamento RPC→HTTP**: `ok=true`→200, `reason=idempotent_replay`→200, `ok=false`→4xx por
  reason, exceção→500. Sem stack trace.
- **Provider atrás da abstração** (ADR-005): `GeocodingProvider`/`RoutingProvider` com
  registry vazio; `/quote` e `/enrich` retornam **501 `geo_provider_not_configured`** até a
  Sessão 20 (Google Maps `TWO_WHEELER`). Trust boundary do pricing preservado (distância do
  provider, nunca do business; nunca haversine — ADR-012 D2).
- **Validação real** (não simulada): regressão 10/10 suítes PASS no dev + vertical slice via
  `next dev`+curl (create→…→SWAC `won→assigned`→OTP→POD→`delivered`), idempotência replay
  confirmada (0 duplicação), internal-auth fail-closed, OTP sensitive (não logado).

Endpoints driver/user-facing (`respond_to_offer`, `submit_proof_of_delivery`, transitions
driver-side via JWT+signed links), webhook router DataCrazy e cookie/middleware full →
**Sessão 15**.