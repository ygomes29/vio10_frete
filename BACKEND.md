# BACKEND.md — Backend do ViO10

## 1. Forma

No MVP o backend vive **dentro do projeto Next.js** (ver ADR-002). Não há serviço
Node separado — a lógica crítica de atomicidade já mora no Postgres via RPCs, então
um serviço extra só aumentaria complexidade sem benefício. Se/ quando surgirem
workers pesados ou filas, extraímos um serviço dedicado.

## 2. Camadas

```
Route Handlers / Server Actions  (entrypoints)
        │
        ▼
Application / Service   (casos de uso, orquestração, autorização)
        │
        ▼
Domain                  (regras determinísticas: pricing, scoring, states, eligibility)
        │
        ▼
Persistence / RPC       (Supabase client, funções atômicas do Postgres)
```

Regras de negócio **não** ficam em componentes React nem espalhadas em Route
Handlers. Route Handlers são finos: validam, autorizam, chamam serviços.

## 3. Entrypoints e fronteiras

- **Route Handlers (`/app/api/...`)** — para integrações externas: n8n, DataCrazy,
  webhooks. Idempotentes, com `idempotency_key` e `external_event_id`.
- **Server Actions** — somente ações originadas no próprio frontend. n8n e
  DataCrazy **não** dependem de Server Actions.
- Toda mutação de estado crítico passa pelo **domínio** e, quando atômica, por
  **RPC do Postgres**.

## 4. Funções RPC atômicas (Postgres)

Ponto central da arquitetura. Operações que não podem depender de timing de camada
externa viram funções transacionais no banco:

## 4. Funções RPC atômicas (Postgres) — estado da implementação

Implementadas na Sessão 03 (`supabase/migrations/0013_rpcs.sql`), todas em
`SECURITY INVOKER` + `search_path` fixo (nunca `SECURITY DEFINER` para bypassar RLS):

- `claim_delivery(p_delivery_request_id, p_driver_id, p_dispatch_round_id,
  p_delivery_offer_id, p_bid_id, p_correlation_id)` — atribuição atômica. `SELECT …
  FOR UPDATE` na `delivery_requests`; valida status=`searching_driver` e offer
  aceitável e não expirada; insere `delivery_assignments` (status active); atualiza
  status=`assigned`; marca offer `won`/demais `lost`; fecha a round; insere
  `delivery_event`. O partial unique index `UNIQUE (delivery_request_id) WHERE
  status='active'` é a garantia física final (`unique_violation` → `already_assigned`).
- `respond_to_offer(p_delivery_offer_id, p_driver_id, p_response_type,
  p_bid_amount_cents, p_idempotency_key, p_correlation_id)` — registra
  ACCEPT/COUNTER_BID/DECLINE idempotentemente. **Não atribui.** ACEITAR =
  `bid_amount_cents = driver_offer_cents`. Uma resposta válida por (offer, driver).
- `transition_delivery(p_delivery_request_id, p_to_status, p_actor_type,
  p_actor_id, p_metadata, p_correlation_id)` — máquina de estados central com matriz
  de transições; supersede assignment anterior em reatribuição; insere `delivery_event`.
- `set_driver_availability(p_driver_id, p_status, p_reason)` — atualiza
  `drivers.current_availability_status` + append em `driver_availability` (log).

Ainda não implementado (Sessão 09/10): `select_winner_and_claim(p_round_id)` —
pontua/ordena candidatos e chama `claim_delivery`. Até lá, a seleção não existe.

## 5. Idempotência

- Endpoints mutantes aceitam cabeçalho `Idempotency-Key`.
- `integration_events(idempotency_key, source, external_event_id, ...)` com
  `UNIQUE(idempotency_key)` por origem garante que retries não dupliquem efeito.
- Webhooks: `webhook_events(source, external_id)` UNIQUE → dedup.
- Respostas repetidas a ofertas/bids: `respond_to_offer` valida offer ativa e
  não expirada; respostas duplicadas retornam o resultado original sem novo efeito.
- **R17 — `external_reference` ≠ `idempotency_key`** (conceitos distintos; ver
  `docs/SECURITY.md`): `idempotency_key` deita retry de *operação*; `external_reference`
  vincula a corrida ao *registro no sistema de origem externa* (`UNIQUE` por
  `organization_id` em `delivery_requests`, pode ser `NULL`); `external_event_id`
  deita *webhook/evento inbound*. Misturá-los quebra a semântica de idempotência.

## 6. Autorização

- **Supabase Auth** para sessão.
- **RBAC** com papéis: `super_admin`, `admin`, `operator`, `business_owner`,
  `business_user`, `driver`.
- **RLS** em toda tabela de domínio (`organization_id`) — defesa em profundidade.
  Mesmo que a API falhe em checar, o banco bloqueia leitura/escrita cross-tenant.
- A camada de serviço **também** autoriza (não confia só no RLS) e define o que
  cada papel pode visualizar/criar/alterar/cancelar/atribuir/consultar.
- **Contextos de execução (user-scoped vs system-scoped)** — ver `ARCHITECTURE.md`
  §3.1: operações de usuário rodam **user-scoped** (JWT `authenticated`, RLS aplica);
  operações do próprio sistema rodam **system-scoped** (`service_role`, bypass de
  RLS). `service_role` **nunca** vaza para n8n/DataCrazy/IA — eles chamam endpoints e
  o backend decide o contexto. O backend **não** promove ação de usuário a system-scoped
  para furar RLS. RPCs são `SECURITY INVOKER` (herdam RLS de quem chama).
- Detalhes em `docs/SECURITY.md`.

## 7. Comunicação com n8n / DataCrazy

- n8n chama Route Handlers do backend (nunca Server Actions, nunca SQL direto).
- DataCrazy chama o backend direto quando apropriado, ou via n8n quando há
  orquestração/temporização. Em ambos os casos: backend → banco.
- Fluxo proibido: `DataCrazy → SQL/banco direto`. Diagramas e docs não podem
  sugerir isso.

## 8. Observabilidade no backend

Toda operação de serviço loga (no mínimo): `correlation_id`, `organization_id`,
`delivery_request_id`, `actor`, `event_type`, `origem`, `resultado`, `erro`.
Erros são capturados e propagados de forma determinística ao chamador (n8n precisa
saber se venceu/perdeu, não apenas se houve exceção).

## 9. Convenções

- TypeScript estrito.
- Nomeação: `*_cents` para dinheiro, `*_at` para timestamps, `*_id` UUID.
- Enums via `pg_enum` no Postgres espelhados no TS.
- Sem lógica de negócio fora do domínio. Sem chamada direta ao Google Maps fora da
  abstração de provider (ver `docs/GEOLOCATION.md`).