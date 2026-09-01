# docs/N8N_WORKFLOWS.md — Workflows n8n

> **Arquitetura** dos workflows desenhada na Sessão 13 (ADR-018), **trigger model
> revisado** na Sessão 16 (ADR-022 — Realtime → Database Webhooks) e **contrato
> alinhado** à camada de API (Sessões 14-15, ADR-019/ADR-020) e ao outbound WhatsApp
> (Sessão 16, ADR-021). Este arquivo fixa as **regras obrigatórias** e o **design
> completo** dos 16 workflows. Assinaturas de RPC e valores de `delivery_event_type`
> aqui são **verificados contra as migrations** (não inventados).
>
> **Status de validação:** design concluído (Sessão 13) + trigger model revisado
> (Sessão 16, ADR-022) + **trigger model provado live** (Sessão 16 Phase 2: pg_net egress,
> dispatcher `VIO10-dispatcher` c/ validação de secret + roteamento por `event_type`, DB
> trigger `trg_delivery_events_notify_n8n` sobre `delivery_events` INSERT → n8n, 4 event
> types com `event_id` exato) + **sub-workflows provados live** (Sessão 16 Phase 3: deploy
> Vercel público `https://vio10-frete.vercel.app` resolveu reachability — sem ECONNREFUSED;
> 8 fluxos backend provados end-to-end c/ chave real: #2-enrich→501 geo, #6-offer→501
> whatsapp, #10-assign→501, #11-update→501 (+branch `in_transit`→otp), #12-notify→501,
> #13-confirm→422 pod_required, #14-failure→not_found, #15-reconciler→200 scan). 3 bugs
> reais do n8n httpRequest v4.2 achados+corrigidos (objeto aninhado, delimitador `{{ }}`,
> URL `{{ }}` inline não resolve). **WhatsApp real PROVEN live** (Sessão 16 Phase 3b: Evolution
> V2 cold — Estágio 1 saída do 501, Estágio 2a backend→Evolution→WhatsApp direto
> `external_id=3EB0C773...`, Estágio 2b cadeia n8n completa `external_id=3EB0B5E3...` ~5s
> latência; ambos confirmados pelo usuário no celular; fix `encodeURIComponent` no
> `evolution-provider.ts:28`, instância `Olivia - NEA`). **Restante Phase 3**: #8-close +
> #9-nova-rodada (bloqueado por geo 501 — Sessão 20) + DataCrazy in-conversation (janela 24h,
> só c/ conversa real) + OTP real ao recebedor (`type:otp`, precisa `in_transit` — geo 501).
> Não simulado (regra mestra).

## Regra obrigatória

> **n8n nunca decide sozinho que uma corrida foi atribuída.** Ele solicita a operação
> ao backend. O backend responde se a atribuição venceu ou perdeu.

- n8n é **orquestrador**, não fonte da verdade ("Banco é a fonte da verdade. Backend
  decide. n8n orquestra" — `CLAUDE.md`).
- n8n **não** escreve estado no banco diretamente; chama **Route Handlers** do backend.
- n8n **não** depende de Server Actions internas (Server Actions só para ações originadas
  no próprio frontend).
- n8n **nunca** decide preço, ETA, entregador ou status — pede a operação; o backend
  retorna o resultado.
- n8n **nunca** chama `claim_delivery` direto (interno ao `select_winner_and_claim`,
  GATE Sessão 10).
- Webhooks e eventos são **idempotentes** (`idempotency_key`, `external_event_id`,
  `external_reference` — R17, não misturar).
- Workflows separados, observáveis, versionáveis — **não** monolíticos.

## Modelo de trigger (ADR-022 D1 — supersede ADR-018 D2)

- **Estado interno** (#2, #6, #8, #10, #11, #13, #14): **Supabase Database Webhooks**
  (`pg_net` + `supabase_functions`) sobre `delivery_events` **INSERT**. O trigger
  Postgres faz `HTTP POST` do registro ao **Webhook node** n8n; um **Switch node**
  roteia por `record.event_type` (D2). **Não** é a publicação `supabase_realtime`
  (canal WebSocket — outra coisa). DB é a fonte da verdade; eventos já são auditados.
- **Reconciler** (parte de #15, periódico): **Schedule Trigger** chama
  `POST /api/internal/reconciler/scan` (read-only, state-based) — backend devolve
  **estado preso** (rodadas `open` expiradas, drafts sem quote, `searching_driver` sem
  rodada). n8n **não query o DB direto** (regra mestra); reprocessa cada achado via
  Route Handlers. Idempotente por estado da corrida.
- **Inbound** (#1, #7, #16): **backend router** (`POST /api/webhooks/datacrazy`,
  ADR-020 D5: signature+dedup+route+200) — DataCrazy/motorista não falam o n8n
  direto. n8n **não** está no caminho inbound (D3 do usuário, ADR-022 D8). Dedup via
  `webhook_events.external_id`.

## Timeout da rodada (ADR-022 D3)

- **Primário**: n8n **Wait node** agendado `response_window_seconds` após #5 abrir a rodada
  → dispara #8 ao expirar.
- **Backstop**: reconciler fecha rodadas com `expires_at < now()` e `status='open'` que o
  Wait perdeu (n8n crash/restart). **Sem schema novo** (`expires_at` existe em 0023); sem
  pg_cron.

## Route Handler contract surface (ADR-018 D5, alinhado Sessões 14-16)

n8n chama estes endpoints; o backend mapeia cada um à RPC/service com o escopo correto.
Os **5 system-only** vão por Route Handlers system-scoped (Service Role interno) — nunca
expostos ao n8n/IA direto. `service_role` jamais no n8n (n8n autentica por
`x-internal-api-key`, ADR-019 D3 / ADR-022 D4).

| Endpoint | Escopo | RPC/service |
|---|---|---|
| `POST /api/internal/deliveries` | system | `create_delivery_request` |
| `POST /api/internal/deliveries/{id}/enrich` | system | `GeocodingProvider.geocode` + validação |
| `POST /api/internal/deliveries/{id}/quote` | system | `RoutingProvider.route` + `create_quote` |
| `POST /api/internal/deliveries/{id}/confirm-quote` | user JWT ou system | `confirm_quote` |
| `POST /api/internal/deliveries/{id}/dispatch/rounds` | system | `open_dispatch_round` |
| `POST /api/internal/dispatch/rounds/{id}/close` | system | `select_winner_and_claim` |
| `POST /api/internal/deliveries/{id}/transitions` | system (path system) | `transition_delivery` (actor system) |
| `POST /api/driver/deliveries/{id}/transitions` | driver (cookie JWT, ADR-020 D1) | `transition_delivery` (actor driver) |
| `POST /api/internal/deliveries/{id}/confirm` | system | `confirm_delivery` |
| `POST /api/internal/deliveries/{id}/otp` | system (**geração-only**, redact `otp_code`, ADR-021 D7) | `generate_delivery_otp` — n8n **não** usa (ver #11) |
| `POST /api/internal/notifications/send` | system (ADR-021 D2) | `sendNotification` (provider híbrido + `notifications`) |
| `POST /api/internal/reconciler/scan` | system, read-only (ADR-021 D5) | `scanReconciler` (state-based) |
| `POST /api/internal/offers/{id}/respond-link` | system (gerador, ADR-020 D4) | signed link generator (chamado internamente por `notifications/send`) |
| `POST /api/offers/{id}/respond` | driver (dual cookie-ou-token, ADR-020 D1) | `respond_to_offer` |
| `POST /api/driver/deliveries/{id}/pod` | driver (cookie JWT, ADR-020 D1) | `submit_proof_of_delivery` |
| `POST /api/driver/availability` | driver (cookie JWT) | `set_driver_availability` |
| `POST /api/webhooks/datacrazy` | público c/ signature HMAC (ADR-020 D5) | router inbound (signature+dedup+route) |

> **Outbound WhatsApp** (#6/#10/#11/#12): n8n **não** envia direto nem gera signed link
> — chama `POST /api/internal/notifications/send` com `{type, offer_id?, delivery_id?}`
> e o backend resolve destinatário, gera o link (se `offer`), escolhe provider híbrido
> (DataCrazy nativo + Evolution fallback, ADR-021 D1), envia e loga em `notifications`
> (idempotente). Segredos ficam no backend.

## Idempotência (R17 — ADR-018 D6, não misturar)

- **`Idempotency-Key`** header → `integration_events.idempotency_key` → **dedup de retry**.
- **`external_event_id`** → `webhook_events.external_id` / `integration_events` → **dedup de
  webhook/event inbound reprocessado**.
- **`external_reference`** → `delivery_requests` UNIQUE por `organization_id` → **dedup de
  criação**.
- **`correlation_id`**: propagação end-to-end (log/trace), **não** é dedup.

## Workflows previstos (16)

1. nova solicitação recebida
2. enriquecimento/geocodificação
3. cotação
4. início de dispatch
5. abertura de rodada
6. envio de ofertas
7. recebimento de respostas
8. timeout da rodada
9. nova rodada
10. atribuição confirmada
11. atualizações da corrida
12. notificações
13. entrega concluída
14. falhas
15. retry/dead-letter + reconciler
16. webhooks DataCrazy

---

## Para cada workflow

### Workflow #1 — nova solicitação recebida

> **Backend router (n8n não está no inbound — ADR-022 D8).** A criação é feita pelo
> backend; o n8n **reage** em #2 ao `delivery_created`.

- **Trigger:** backend — DataCrazy inbound → router `/api/webhooks/datacrazy` (após a IA
  estruturar o pedido) **ou** dashboard do business → Server Action. Ambos chamam a RPC
  de criação (backend interno, `service_role`). Origem `whatsapp` ou `integration`.
- **Input:** `organization_id`, `business_id`, `business_location_id`, endereços/contatos
  de coleta e entrega, `vehicle_required`, `priority`, `scheduled_at`, `external_reference`,
  `items`, `notes`, `instructions`, `correlation_id`.
- **Validações:** campos obrigatórios presentes (se dado faltante → roteia de volta ao
  agente de pedidos da IA para perguntar ao cliente; **não** cria corrida incompleta);
  `external_reference` presente (dedup de criação).
- **Operações:** chama `POST /api/internal/deliveries` (system). O Route Handler resolve o
  ator a partir do contexto e chama
  `create_delivery_request(p_organization_id, p_business_id, p_business_location_id,
  p_pickup_address, p_pickup_lat, p_pickup_lng, p_pickup_contact_name,
  p_pickup_contact_phone, p_delivery_address, p_delivery_lat, p_delivery_lng,
  p_delivery_contact_name, p_delivery_contact_phone, p_vehicle_required, p_priority,
  p_scheduled_at, p_origin, p_external_reference, p_notes, p_instructions, p_items,
  p_correlation_id) → (ok, reason, delivery_request_id)`. Cria em `draft` + itens + evento
  `delivery_created` (ADR-011). **Sem preço.**
- **Chamadas ao backend:** `POST /api/internal/deliveries`.
- **Eventos gerados:** `delivery_created` (pela RPC).
- **Retries:** backoff exponencial; DLQ após N (#15).
- **Idempotency key:** `external_reference` (criação dedup — duas calls para o mesmo pedido
  externo retornam o mesmo `delivery_request_id`) + `Idempotency-Key` header (retry dedup).
- **Tratamento de erro:** `not_authorized`/`invalid_param` → loga + alerta (#12), não cria;
  `external_reference` duplicado → retorna id existente (no-op). Dado faltante → volta à IA.
- **Logs:** `correlation_id`, `organization_id`, `external_reference`, `origin`, resultado.
  Sem PII além do necessário ao pedido.

### Workflow #2 — enriquecimento/geocodificação

- **Trigger:** Database Webhook `delivery_created` (Switch
  `record.event_type='delivery_created'`).
- **Input:** `delivery_request_id`, `correlation_id` (do evento).
- **Validações:** delivery em `draft`; pontos ainda não enriquecidos (idempotência — se já
  enriquecido, no-op).
- **Operações:** chama `POST /api/internal/deliveries/{id}/enrich` (system). O Route
  Handler invoca `GeocodingProvider.geocode` (address→coords se faltar), `reverse`,
  `validateAddress`, snap-to-road, qualidade de endereço; persiste pontos/enriquecimento.
  Prepara para #3. (Sequenciamento detalhado em D8 — o geocode inicial para satisfazer
  `pickup_point`/`delivery_point` NOT NULL pode acontecer em #1; #2 é enriquecimento/
  validação.)
- **Chamadas ao backend:** `POST /api/internal/deliveries/{id}/enrich`.
- **Eventos gerados:** nenhum novo (enriquecimento é preparação; não transita estado).
- **Retries:** backoff exponencial; falha de provider → DLQ; reconciler reprocessa drafts
  sem enrich (ADR-022 D6).
- **Idempotency key:** estado (`draft` + já-enriquecido) + `Idempotency-Key`.
- **Tratamento de erro:** endereço não encontrado/ambíguo → notifica business (#12) para
  corrigir; não avança para #3.
- **Logs:** `correlation_id`, `delivery_request_id`, qualidade do endereço, resultado.
  Sem PII de contato.

### Workflow #3 — cotação

- **Trigger:** encadeado de #2 (após enriquecimento bem-sucedido) **ou** reconciler (drafts
  sem quote, D2).
- **Input:** `delivery_request_id`, `correlation_id`.
- **Validações:** delivery em `draft` (re-quote de `quoted`+ → `wrong_state`); existe
  regra de pricing (org→global, ADR-012 D4).
- **Operações:** chama `POST /api/internal/deliveries/{id}/quote` (system). O Route Handler
  invoca `RoutingProvider.route(origin, destination, {travelMode: TWO_WHEELER|CAR})` →
  `{distance_meters, duration_seconds}` — **do provider, nunca do business** (trust
  boundary, ADR-012 D1) — e chama `create_quote(p_delivery_request_id, p_distance_meters,
  p_duration_seconds, p_correlation_id) → (ok, reason, quote_id)`. System-only.
  `draft → quoted`; emite `quote_created`.
- **Chamadas ao backend:** `POST /api/internal/deliveries/{id}/quote`.
- **Eventos gerados:** `quote_created`.
- **Retries:** backoff exponencial; DLQ após N.
- **Idempotency key:** estado (`draft`-only) + `Idempotency-Key`.
- **Tratamento de erro:** `no_pricing_rule` → notifica business/admin, **não** avança;
  encaminha para #14 se configurado como terminal. `wrong_state` → no-op.
- **Logs:** `correlation_id`, `delivery_request_id`, `distance_meters`,
  `duration_seconds`, `quote_id`, resultado. **Sem valor monetário logado como segredo**
  (faixa de preço vem da RPC; não há segredo aqui).

### Workflow #4 — início de dispatch

- **Trigger:** Database Webhook `dispatch_started` (emitido por `confirm_quote` quando o business
  confirma a cotação no dashboard — ADR-013 D1). n8n **reage**; **não** confirma.
- **Input:** `delivery_request_id`, `correlation_id`.
- **Validações:** delivery em `searching_driver`; sem rodada aberta (guard).
- **Operações:** n8n inicializa o **contexto de dispatch** (round-1 params: raio inicial,
  `max_candidates`, `driver_offer_cents`, `response_window_seconds` — das constantes/env do
  n8n, D4) e chama #5. n8n não transita estado; `confirm_quote` já fez `quoted →
  searching_driver`.
- **Chamadas ao backend:** nenhuma direta (delega a #5).
- **Eventos gerados:** nenhum novo (o evento consumido é `dispatch_started`).
- **Retries:** se #5 falhar, backoff; reconciler (ADR-022 D6) reprocessa
  `searching_driver` sem rodada aberta.
- **Idempotency key:** estado (`searching_driver` + rodada aberta) — abrir rodada duplicada
  → `round_already_open`.
- **Tratamento de erro:** params inválidos → loga + alerta; não abre rodada.
- **Logs:** `correlation_id`, `delivery_request_id`, round-1 params, resultado.

### Workflow #5 — abertura de rodada

- **Trigger:** encadeado de #4 (round 1) / #9 (round N+1).
- **Input:** `delivery_request_id`, `search_radius_m`, `max_candidates`,
  `driver_offer_cents`, `response_window_seconds`, `correlation_id`.
- **Validações:** delivery em `searching_driver`; sem rodada aberta (`round_already_open`
  guard); raio/params > 0.
- **Operações:** chama `POST /api/internal/deliveries/{id}/dispatch/rounds` (system). O
  Route Handler chama `open_dispatch_round(p_delivery_request_id, p_search_radius_m,
  p_max_candidates, p_driver_offer_cents, p_response_window_seconds,
  p_max_location_age_seconds, p_correlation_id) → (ok, reason, round_id,
  candidate_count)`. System-only. Cria rodada (mesmo com 0 candidatos — snapshot de
  auditoria, ADR-013 D4); emite `round_opened` + `offer_created` por candidato.
  `candidate_count=0` → #8 (fecha → `no_candidates` → #9). `>0` → #6 (por offer) **e**
  agenda Wait node #8 para `response_window_seconds`.
- **Chamadas ao backend:** `POST /api/internal/deliveries/{id}/dispatch/rounds`.
- **Eventos gerados:** `round_opened`, `offer_created` (por offer).
- **Retries:** backoff exponencial; DLQ após N.
- **Idempotency key:** `round_already_open` (não abre sobreposta) + `Idempotency-Key`.
- **Tratamento de erro:** `round_already_open` → no-op (reconciler/Wait cuida do close);
  `wrong_state` → no-op.
- **Logs:** `correlation_id`, `delivery_request_id`, `round_id`, `round_number`,
  `candidate_count`, params.

### Workflow #6 — envio de ofertas

- **Trigger:** Database Webhook `offer_created` (Switch `record.event_type='offer_created'`).
- **Input:** `delivery_offer_id`, `driver_id`, `round_id`, `correlation_id` (do evento).
- **Validações:** offer válida e aberta; rodada ainda `open` (idempotência — segundo trigger
  da mesma offer → no-op).
- **Operações:** chama `POST /api/internal/notifications/send` (system) com
  `{type:'offer', offer_id}`. O **backend** resolve offer+driver+delivery, **gera o signed
  link** (`createActionLink`, TTL = restante até `delivery_offers.expires_at`, clamp
  60..900, ADR-020 D3), monta a **mensagem de decisão** (região de coleta/destino, distância,
  veículo, valor `driver_offer_cents`, prazo + link — **sem PII do cliente antes da
  atribuição**, ADR-018 D10), escolhe provider híbrido (ADR-021 D1), envia ao motorista
  (`drivers.phone`) e loga em `notifications`. n8n **não** gera o link nem envia direto.
- **Chamadas ao backend:** `POST /api/internal/notifications/send` (`Idempotency-Key:
  {correlation}-offer-{offer_id}`).
- **Eventos gerados:** nenhum novo pelo envio em si (a notificação é logada em `notifications`).
- **Retries:** falha de provider → backoff; `releaseClaim` libera a claim p/ retry
  re-executar (ADR-021 D2 fix). Não reenviar duplicado (`notifications.idempotency_key`).
- **Idempotency key:** `notifications.idempotency_key` = `notif:offer:{offer_id}` (upsert
  ignore-duplicates) + `Idempotency-Key` header (retry dedup, R17).
- **Tratamento de erro:** provider 501 (`whatsapp_provider_not_configured`) → backoff +
  DLQ após N + alerta (#12); offer expirada/rodada fechada → não envia (backend retorna
  reason).
- **Logs:** `correlation_id`, `delivery_offer_id`, `driver_id`, `round_id`, canal,
  resultado. **Sem PII do cliente.**

### Workflow #7 — recebimento de respostas

- **Trigger:** inbound — motorista clica no **signed link** (HMAC, ADR-020 D3) →
  `POST /api/offers/{id}/respond` (driver-facing, **dual auth cookie-ou-token**, ADR-020
  D1). O link é gerado pelo backend em #6 (`notifications/send`); o motorista vem por
  WhatsApp (sem cookie) usando o token do link, ou pelo app driver (cookie JWT).
- **Input:** `delivery_offer_id`, `driver_id` (resolvido do token/cookie, **não** do
  body), `response_type` (`accept`|`counter_bid`|`decline`), `bid_amount_cents` (se
  counter_bid), `idempotency_key`, `correlation_id`.
- **Validações:** offer existe e não expirada; rodada aberta; motorista é o dono da offer
  (IDOR `o===offerId` + timing-safe, ADR-020 D3 — resolvido no backend, não confia no
  client).
- **Operações:** chama `POST /api/offers/{id}/respond` (driver, dual). O Route Handler
  chama `respond_to_offer(p_delivery_offer_id, p_driver_id, p_response_type,
  p_bid_amount_cents, p_idempotency_key, p_correlation_id) → (ok, reason, bid_id)`.
  Driver-scoped. **Não atribui** — ACEITAR ≠ GANHAR (ADR-006). Emite `offer_accepted` /
  `counter_bid_received` / `offer_declined` (que disparam DB Webhooks → #12).
- **Chamadas ao backend:** `POST /api/offers/{id}/respond` (n8n **não** chama — é o
  motorista; o n8n reage ao `offer_*` event via DB Webhook em #12).
- **Eventos gerados:** `offer_accepted` / `counter_bid_received` / `offer_declined`.
- **Retries:** backoff exponencial; DLQ após N.
- **Idempotency key:** `p_idempotency_key` — uma resposta válida por (offer, driver);
  duplicata retorna o resultado original.
- **Tratamento de erro:** offer expirada → backend retorna reason (410); notifica
  motorista. Já respondida → `offer_already_responded` (409, no-op). Já atribuída
  (concorrente) → backend trata; n8n no-op.
- **Logs:** `correlation_id`, `delivery_offer_id`, `driver_id`, `response_type`,
  `bid_amount_cents` (se lance), resultado. **Sem PII do cliente.**

### Workflow #8 — timeout da rodada

- **Trigger:** **(a) n8n Wait node** (`response_window_seconds` após #5) primário **ou**
  **(b) reconciler** (rodadas `expires_at < now()` e `status='open'`, D3 backstop).
- **Input:** `dispatch_round_id`, `correlation_id`. (Pesos de scoring
  `p_weight_price`/`p_weight_distance` do config do n8n, D4.)
- **Validações:** rodada `open` (idempotência — `round_not_open` se já fechada).
- **Operações:** chama `POST /api/internal/dispatch/rounds/{id}/close` (system). O Route
  Handler chama `select_winner_and_claim(p_dispatch_round_id, p_weight_price,
  p_weight_distance, p_max_location_age_seconds, p_correlation_id) → (ok, reason,
  winner_driver_id, winner_offer_id, winner_bid_id)`. System-only. Pontua candidatos
  (responded + ainda-eligible), escolhe vencedor (tie-break determinístico) e chama
  `claim_delivery` **atomicamente** na mesma transação (GATE Sessão 10). Emite
  `round_closed` + `winner_selected` + `driver_assigned` (se won).
- **Chamadas ao backend:** `POST /api/internal/dispatch/rounds/{id}/close`
  (`Idempotency-Key: {correlation}-close-{round_id}`).
- **Eventos gerados:** `round_closed` (sempre — com `metadata.reason` = `won`/`no_candidates`/
  `superseded_by_concurrent_claim`), `winner_selected` + `driver_assigned` (se won) — pela
  RPC. `superseded_by_concurrent_claim` é **metadata.reason do evento `round_closed`**,
  não um event_type nem o retorno HTTP.
- **Retries:** `round_not_open` → no-op (idempotente); falha transitória → backoff
  (`releaseClaim` libera a claim, ADR-021 D2).
- **Idempotency key:** estado da rodada (`open`→`closed`) — `round_not_open` guarda
  re-close.
- **Tratamento de erro:** resultado `won` → #10. `no_candidates` → #9 (nova rodada).
  `already_assigned`/`not_searching_driver`/`delivery_not_found` (race de outra
  rodada já ganhou — RPC 0024:209 retorna o `claim_reason`; emite `round_closed` com
  metadata `superseded_by_concurrent_claim`) → ignora. `round_not_open` → no-op.
  `not_authorized` → alerta.
- **Logs:** `correlation_id`, `dispatch_round_id`, resultado, `winner_driver_id` (se won).
  Scores no `metadata` do evento (não em coluna — ADR-014 D6).

### Workflow #9 — nova rodada

- **Trigger:** encadeado de #8 (`no_candidates`).
- **Input:** `delivery_request_id`, `round_number` atual, `correlation_id`.
- **Validações:** delivery ainda `searching_driver` (se já `assigned` por concorrência →
  ignora); `round_number < max_rounds` (config n8n, D4).
- **Operações:** calcula próximos params (raio maior, `driver_offer_cents` talvez maior,
  `response_window_seconds` igual/menor — do config); se `max_rounds` exaurido →
  `transition_delivery('expired')` (system, #14 terminal); senão → chama #5.
- **Chamadas ao backend:** (terminal) `POST /api/internal/deliveries/{id}/transitions`
  system → `transition_delivery(p_delivery_request_id, 'expired', 'system', null,
  metadata, p_correlation_id)`.
- **Eventos gerados:** `expired` (se exaurido) — pela RPC.
- **Retries:** se #5 falhar, backoff; reconciler reprocessa `searching_driver` sem rodada
  aberta (ADR-022 D6).
- **Idempotency key:** `round_already_open` (não abre sobreposta) + estado da corrida.
- **Tratamento de erro:** entrega já `assigned` (concorrente) → no-op.
- **Logs:** `correlation_id`, `delivery_request_id`, `round_number`, próximos params ou
  `expired`.

### Workflow #10 — atribuição confirmada

- **Trigger:** Database Webhook `driver_assigned` (Switch
  `record.event_type='driver_assigned'`; emitido por `claim_delivery` dentro do SWAC).
- **Input:** `delivery_request_id`, `winner_driver_id`, `correlation_id` (do evento).
- **Validações:** delivery em `assigned`; notificação ainda não enviada (idempotência —
  segundo trigger → no-op).
- **Operações:** chama `POST /api/internal/notifications/send` (system) com
  `{type:'assignment', delivery_id}`. O backend resolve a assignment ativa + **PII
  liberada pós-atribuição** (endereços, contatos), monta a mensagem completa da corrida
  ao motorista + ao business, escolhe provider híbrido, envia e loga. **Default: OTP em
  `in_transit`** (não aqui) — este workflow **não** gera OTP no assignment (alternativa
  "OTP no assignment" desativada no MVP).
- **Chamadas ao backend:** `POST /api/internal/notifications/send`
  (`Idempotency-Key: {correlation}-assignment-{delivery_id}`). Nenhuma mutante de estado
  (a transição já foi feita pelo SWAC).
- **Eventos gerados:** nenhum novo (consome `driver_assigned`).
- **Retries:** falha de provider → backoff (`releaseClaim`); após N → DLQ + alerta (#12).
- **Idempotency key:** `notifications.idempotency_key` = `notif:assignment:{delivery_id}`
  + `Idempotency-Key` header.
- **Tratamento de erro:** provider indisponível → backoff; já notificado → no-op (replay).
- **Logs:** `correlation_id`, `delivery_request_id`, `winner_driver_id`, destinatários.

### Workflow #11 — atualizações da corrida

- **Trigger:** Database Webhook `driver_to_pickup` / `arrived_at_pickup` / `picked_up` /
  `in_transit` (transições driver-initiated via app → `transition_delivery`
  driver-scoped — #11 **reage**, não faz a transição).
- **Input:** `delivery_request_id`, `event_type`, `correlation_id` (do evento).
- **Validações:** evento corresponde ao estado atual da corrida (idempotência — segundo
  trigger do mesmo evento → no-op).
- **Operações:**
  - notifica partes relevantes: chama `POST /api/internal/notifications/send` (system)
    com `{type:'status_update', delivery_id}` → backend notifica business/motorista
    conforme o evento (escolhe provider, loga).
  - em `in_transit` → dispara **OTP-send ao recebedor**: chama
    `POST /api/internal/notifications/send` (system) com `{type:'otp', delivery_id}`. O
    backend chama `generate_delivery_otp` **internamente** (plaintext `otp_code` fica no
    backend), monta a mensagem ao recebedor (`delivery_contact_phone`), envia via provider
    híbrido e loga em `notifications` (só metadados). **Response `{ok, reason}` sem
    `otp_code`** (ADR-021 D7). Emite `otp_generated`. **n8n NÃO chama
    `/api/internal/deliveries/{id}/otp`** (geração-only, redact; ver ADR-022 D5) — o
    plaintext nunca transita pelo n8n.
- **Chamadas ao backend:** `POST /api/internal/notifications/send` (status_update e, em
  `in_transit`, otp).
- **Eventos gerados:** `otp_generated` (pela RPC dentro de `notifications/send`, no
  OTP-send em `in_transit`).
- **Retries:** backoff exponencial; `releaseClaim` em falha transitória (provider 501);
  DLQ após N.
- **Idempotency key:** `notifications.idempotency_key` = `notif:otp:{delivery_id}` (OTP,
  unique) / `notif:status_update:{delivery_id}:{status}` + `Idempotency-Key` header
  (`{correlation}-{op}`, R17).
- **Tratamento de erro:** provider 501/lockout → backoff + alerta (#12); não bloqueia a
  transição (que já ocorreu).
- **Logs:** `correlation_id`, `delivery_request_id`, `event_type`, resultado. **Nunca
  logar o plaintext do OTP.**

### Workflow #12 — notificações

- **Trigger:** Database Webhook em eventos relevantes (`delivered`, `cancelled`,
  `failed`, `expired`, `offer_accepted`/`counter_bid_received`/`offer_declined`,
  etc.) **e** invocado por outros workflows em erro. (#6/#10/#11 enviam suas próprias
  notificações via `notifications/send`; #12 cuida dos terminais/status genéricos.)
- **Input:** `delivery_request_id`, `event_type`, `correlation_id` (do evento).
- **Validações:** destinatário certo por evento (business/motorista/recebedor);
  idempotência (segundo trigger → no-op).
- **Operações:** chama `POST /api/internal/notifications/send` (system) com
  `{type:'terminal'|'status_update', delivery_id}` (+ `status` se aplicável). O backend
  seleciona destinatário/template por evento (PII minimizada — ADR-018 D10), escolhe
  provider híbrido, envia e loga em `notifications`. n8n não envia direto.
- **Chamadas ao backend:** `POST /api/internal/notifications/send`.
- **Eventos gerados:** nenhum (log de notificação).
- **Retries:** falha de provider → backoff (`releaseClaim`); após N → DLQ + alerta.
- **Idempotency key:** `notifications.idempotency_key` = `notif:{type}:{delivery_id}[:{status}]`
  + `Idempotency-Key` header.
- **Tratamento de erro:** provider indisponível → backoff; destinatário sem contato →
  loga + alerta admin.
- **Logs:** `correlation_id`, `delivery_request_id`, destinatário, canal, template,
  resultado. PII mínima.

### Workflow #13 — entrega concluída

> Design Sessão 12 (ADR-017 D6); formalizado no template Sessão 13; trigger model
> revisado Sessão 16 (ADR-022). Implementação live Phase 2 (n8n provisionado).

**Objetivo:** auto-confirmar a entrega quando o driver submete o POD de delivery, sem que
o driver ou o frontend marquem `delivered`. Honra o two-phase POD (Sessão 11/12):
**submeter POD ≠ entregue** — o sistema confirma.

- **Trigger:** Database Webhook `pod_submitted` (Switch
  `record.event_type='pod_submitted' and metadata->>'pod_type'='delivery'`). Reconciler
  captura `pod_submitted` perdido (D6).
  Idempotente por `external_event_id`/`idempotency_key`.
- **Input:** `delivery_request_id`, `pod_id`, `correlation_id`.
- **Validações:** delivery em `in_transit` (senão ignora/sai — já confirmada ou
  cancelada); POD delivery existe e não foi já confirmado (se já `delivered` → no-op).
- **Operações:** chama `POST /api/internal/deliveries/{id}/confirm` (system-scoped,
  Service Role interno) com `{geo_tolerance_m?, correlation_id}`. O Route Handler chama
  `confirm_delivery(p_delivery_request_id, p_geo_tolerance_m, p_correlation_id) →
  (ok, reason, pod_id)`. System-only. Valida POD delivery existe →
  `transition_delivery('delivered')` **re-valida** POD gate + geo gate → transita
  `in_transit → delivered`.
- **Chamadas ao backend:** `POST /api/internal/deliveries/{id}/confirm`.
- **Eventos gerados:** `delivered` (pela `transition_delivery`), com `metadata.pod_id` e
  `metadata.geo_tolerance_m`.
- **Retries:** exponenciais com backoff; dead-letter após N (#15). Idempotência garantida por
  `correlation_id` + estado (`delivered` once — segundo trigger encontra `delivered` →
  no-op).
- **Idempotency key:** estado da corrida (`in_transit`→`delivered` once) + `correlation_id`.
- **Tratamento de erro:**
  - `pod_geolocation_out_of_range` → notifica o driver (via #12) que o POD está fora da
    tolerância; ele deve re-submeter ou contatar suporte; **não** força `delivered`.
    Orquestrador decide (reabrir janela de re-submissão ou escalar para admin).
  - `pod_required`/outros reasons → loga + escala (#14).
- **Geolocalização:** `geo_tolerance_m` (default 200m se omitido) é repassado ao metadata
  da transição; o gate de geo (ADR-017 D2) compara `location_point` do POD ao
  `delivery_point` via `st_distance`. POD sem location → skip do gate (MVP).
- **Pré-requisito de OTP:** o workflow **não** valida o OTP — isso já aconteceu em
  `submit_proof_of_delivery` (D1) antes de `pod_submitted` ser emitido. Se o OTP falhou, o
  submit retornou erro e `pod_submitted` **não** foi emitido. O workflow só vê submits
  bem-sucedidos. (Foto-only ainda funciona — evidência sem verificação de recebedor.)
- **Logs:** `correlation_id`, `delivery_request_id`, `pod_id`, `geo_tolerance_m`,
  resultado. **Sem plaintext de OTP** (já consumido, só hash no banco).

**Dependência externa:** o envio do OTP ao recebedor (#11 em `in_transit`, via
`POST /api/internal/notifications/send {type:'otp'}` → backend gera+envia, ADR-021 D2/D7)
ocorre **antes** do submit. Sem OTP entregue, o driver não tem `otp_code` válido (mas
foto-only ainda funciona). O plaintext do OTP nunca transita pelo n8n (ADR-022 D5).

### Workflow #14 — falhas

- **Trigger:** Database Webhook `cancelled` / `failed` / `expired` (Switch
  `record.event_type in ('cancelled','failed','expired')`) **e** invocado por outros
  workflows em erro (`no_pricing_rule`, `max_rounds`, geo out-of-range escalado, DLQ).
  (`assignment_superseded` **não é event_type** — é `metadata.reason` do `round_closed`.)
- **Input:** `delivery_request_id`, `event_type` ou reason, `correlation_id`.
- **Validações:** estado atual não-terminal (se já terminal → no-op).
- **Operações:** classifica a falha; transita terminal se ainda não (`transition_delivery`
  system com `metadata.reason` — `cancelled`/`failed`/`expired`); notifica business/admin
  (#12); escala humano se preciso.
- **Chamadas ao backend:** `POST /api/internal/deliveries/{id}/transitions` (system) →
  `transition_delivery(p_delivery_request_id, p_to_status, 'system', null, metadata,
  p_correlation_id)`.
- **Eventos gerados:** `cancelled`/`failed`/`expired` (pela RPC, se transitar).
- **Retries:** falha ao transitar terminal → backoff; reconciler garante convergência.
- **Idempotency key:** estado (terminal once).
- **Tratamento de erro:** transição já feita → no-op; reason desconhecido → DLQ + humano.
- **Logs:** `correlation_id`, `delivery_request_id`, reason, classificação, resultado.

### Workflow #15 — retry/dead-letter + reconciler

- **Trigger:** interno (n8n Error Trigger / retry policy) **e** **Schedule Trigger**
  (cron) p/ reconciler (ADR-022 D6).
- **Input:** workflow/execution em falha (retry) **ou** resposta do scan (reconciler).
- **Validações:**
  - retry: execução falhou < N vezes;
  - reconciler: chama `POST /api/internal/reconciler/scan` (system, read-only) — o
    **backend** devolve **estado preso**: (a) rodadas `open` com `expires_at < now()`;
    (b) drafts sem quote há > `stale_after_seconds`; (c) `searching_driver` sem rodada
    aberta. **State-based, não event-based** — não rastreia "qual evento o n8n processou";
    procura estado stuck e reage (sidestepa "evento perdido" do DB Webhook).
- **Operações:**
  - **retry**: backoff exponencial (max N, ex.: 3-5); após N → dead-letter queue + alerta
    (#12). DLQ exige intervenção humana.
  - **reconciler** periódico: reprocessa cada achado via Route Handlers — (a)→#8 (close),
    (b)→#3 (quote), (c)→#5/#9 (abrir/expandir rodada). n8n **não query o DB direto**
    (regra mestra).
- **Chamadas ao backend:** `POST /api/internal/reconciler/scan` (scan) + os endpoints
  dos workflows reprocessados. Sem `Idempotency-Key` no scan (ledger `skip` → re-query
  sempre; cachear scan seria stale).
- **Eventos gerados:** nenhum novo (reprocessa; os workflows reprocessados geram).
- **Retries:** o próprio retry é este workflow; DLQ é terminal aqui.
- **Idempotency key:** idempotência (D6) garante que retry/reprocess **não duplique
  efeito** — estado/`Idempotency-Key` ({correlation}-{op}, R17).
- **Tratamento de erro:** reprocessar workflow que falha repetidamente → DLQ + alerta
  humano.
- **Logs:** `correlation_id`, workflow, reason, tentativa, achados do reconciler.

### Workflow #16 — webhooks DataCrazy

> **Backend router (n8n não está no inbound — ADR-022 D8).** O router do backend
> (`/api/webhooks/datacrazy`) é o entrypoint; n8n reage aos eventos emitidos.

- **Trigger:** inbound HTTP de DataCrazy/WhatsApp (`POST /api/webhooks/datacrazy` —
  backend, ADR-020 D5: signature HMAC + dedup `webhook_events.external_id` + route + 200).
- **Input:** payload DataCrazy (intent estruturado pela IA ou mensagem crua),
  `external_event_id`, signature.
- **Validações:** verifica signature; dedup via `webhook_events.external_id`
  (`external_event_id`); payload bem-formado.
- **Operações:** dedup; parse de intent (IA já estruturou, ou mensagem crua → IA para
  interpretar); roteia **a endpoints backend** (n8n reage aos eventos emitidos):
  - nova solicitação → `POST /api/internal/deliveries` (backend cria) → `delivery_created`
    → n8n #2;
  - resposta de motorista (clique em signed link) → `POST /api/offers/{id}/respond`
    (driver) → `offer_*` → n8n #12;
  - confirmação de OTP-send / outro intent → endpoint correspondente;
  - intent desconhecido → IA re-pergunta ao usuário **ou** DLQ.
- **Chamadas ao backend:** `POST /api/webhooks/datacrazy` (router) → roteia aos endpoints
  de criação/resposta/etc. (backend); n8n reage via DB Webhook.
- **Eventos gerados:** nenhum (inbound router).
- **Retries:** backoff; payload inválido → DLQ.
- **Idempotency key:** `webhook_events.external_id` (inbound reprocessado dedup).
- **Tratamento de erro:** signature inválida → 401, descarta; duplicado → no-op (200);
  intent desconhecido → IA ou DLQ.
- **Logs:** `correlation_id`, `external_event_id`, origem, intent roteado, resultado. PII
  mínima.

---

## Caminho feliz (a construir primeiro na Phase 2 — ADR-022)

```
[backend cria: router/Server Action #1] → delivery_created → enrich(#2) → quote(#3) →
dispatch_started(#4) → open_round(#5) → offer_created → send_offers(#6: notifications/send
type:offer) → [driver aceita #7: /api/offers/{id}/respond] → round_closed(#8: won via
SWAC) → driver_assigned(#10: notifications/send type:assignment) → in_transit(#11:
notifications/send type:otp + status_update) → pod_submitted(#13: /confirm) → delivered
```

Cada seta `event_type` é um DB Webhook → Switch → Execute Sub-workflow. `notifications/send`
é o único canal outbound (backend envia+loga; n8n só dispara). Depois: timeout sem
vencedor (#8 → #9 → #5), rejeições, erros, indisponibilidade, reatribuição, terminais
(#14), retry/reconciler (#15: `/reconciler/scan`).

## Logging

Cada integração tem logging suficiente para diagnóstico. **Nunca** exponha secrets nos
logs. Eventos críticos carregam `correlation_id`, `organization_id`,
`delivery_request_id`, origem, resultado. **PII minimizada** (ADR-018 D10): telefone do
recebedor só no envio do OTP; **nunca** logar plaintext do OTP; **sem PII do cliente** nas
ofertas antes da atribuição.

## Registro final (Phase 2 — Sessão 16 live)

Ao concluir a Phase 2 (n8n provisionado pelo usuário: URL + Public API key + versão),
documentar aqui: ID/nome/função de cada workflow importado, credencial `httpHeaderAuth`
do DB Webhook (sem secrets), versão do n8n, webhook Supabase criado (table
`delivery_events`, event INSERT), e resultado da validação live do caminho feliz.
**Não simulado** (regra mestra).