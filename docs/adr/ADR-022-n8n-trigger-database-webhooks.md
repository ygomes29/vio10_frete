# ADR-022 — Trigger model n8n: Database Webhooks sobre `delivery_events` (supersede ADR-018 D2)

- **Status**: Aprovado
- **Data**: 2026-08-31
- **Sessão**: 16
- **Supersede**: ADR-018 D2 (modelo de trigger Realtime+reconciler) — **parcial**. ADR-018
  D1/D3-D11 íntegros. Apenas o mecanismo de reação a eventos muda: Realtime → Database
  Webhooks.

## Contexto

A ADR-018 (Sessão 13) definiu o design dos 16 workflows n8n e, no **D2**, escolheu
**Supabase Realtime** sobre `delivery_events` (filtro por `event_type`) como trigger de
estado interno, com reconciler periódico de backstop. Era um **design** — a Sessão 13
deixou explícito que implementação + validação live ficavam para a Sessão 14/16 (não
simular PASS, regra mestra).

Na Sessão 16, ao aproximar a implementação, três fatos mudaram o quadro:

1. **Decisão do usuário D3 (Sessão 16)**: o backend é o **único entrypoint inbound**; o
   n8n **reage** a eventos via **Supabase Database Webhooks**, não fica no caminho
   inbound. Isso reposiciona o n8n como reagente a `delivery_events`, não como
   assinante WebSocket.
2. **n8n não tem trigger nativo de Supabase Realtime.** Realtime é um canal WebSocket
   (Publicação `supabase_realtime`, `SUBSCRIBE`/`FILTER`) — exigiria um cliente WS
   persistente no n8n (WebSocket Trigger + reconexão + re-subscribe + repersistência de
   posição). Operação frágil para um orquestrador self-hosted.
3. **Database Webhooks mapeiam limpo a um n8n Webhook node.** Supabase Database Webhooks
   = `pg_net` + schema `supabase_functions`: um trigger Postgres faz `HTTP POST` do
   registro (INSERT/UPDATE/DELETE) a uma URL-alvo. Um **Webhook node** n8n recebe isso
   nativamente — sem WS, sem reconexão manual, durável por construção.

A investigação live confirmou o mecanismo: em dev, `pg_net` está **disponível mas não
instalado** e o schema `supabase_functions` está **ausente** (Database Webhooks não
provisionados); a publicação `supabase_realtime` é **outra coisa** (canal WebSocket para
Realtime, **não** usada por Database Webhooks). Ou seja: nenhuma das duas está "pronta" —
ambas exigem provisionamento. Diante disso, Database Webhooks é a escolha de menor
fragilidade operacional.

## Decisões

### D1 — Database Webhooks (pg_net + supabase_functions) sobre `delivery_events` INSERT

- Um **Database Webhook** Supabase sobre a tabela `delivery_events`, evento **INSERT**,
  faz `HTTP POST` à URL do **Webhook node** n8n. O payload é o registro inserido
  (`{id, delivery_request_id, event_type, actor_type, actor_id, metadata, created_at}`).
- **Sem filtro por `event_type` na configuração do webhook** — Database Webhooks
  disparam por (tabela, evento), não por valor de coluna. O n8n recebe **todos** os
  INSERTs de `delivery_events` e faz o roteamento num **Switch node** sobre
  `record.event_type` (D2). Isso é deliberado: o `delivery_events` é a auditoria canônica
  (uma fonte, GATE Sessão 11), e o Switch é determinístico.
- **Não é a publicação `supabase_realtime`** — esta serve ao Realtime WebSocket e não é
  tocada. Database Webhooks é infra separada (`pg_net` + `supabase_functions`).
- **Provisão (dev)**: habilitar `pg_net` e criar o webhook via Dashboard/Management
  apontando à URL n8n — **Phase 2 live** (requer URL-alvo n8n; deferred, não simulado).

### D2 — Roteamento no n8n: Webhook node → Switch `event_type` → Execute Sub-workflow

O Webhook node entrega `record`; um **Switch node** particiona por `record.event_type`
e despacha cada branch a um **Execute Sub-workflow** (um por workflow #2-#14). Cada
sub-workflow é versionável/observável isoladamente (regra "não monolítico", ADR-018 D1).

Mapeamento `event_type` → workflow (verificado contra as 23 enum values, ADR-018):

| `event_type` | Workflow | Ação |
|---|---|---|
| `delivery_created` | #2 | enriquecer |
| `quote_created` | — | (no-op: #3 encadeia de #2, não de evento) |
| `dispatch_started` | #4 | iniciar dispatch → #5 |
| `round_opened` | — | (no-op: #5 encadeia de #4) |
| `offer_created` | #6 | enviar oferta ao motorista |
| `offer_accepted` / `counter_bid_received` / `offer_declined` | #12 | notificar (a resposta foi gravada em #7, inbound) |
| `round_closed` | #8 | ramificar: `won`→#10, `no_candidates`→#9 |
| `winner_selected` | — | (consumido dentro do close) |
| `driver_assigned` | #10 | notificar atribuição (PII liberada) |
| `driver_to_pickup` / `arrived_at_pickup` / `picked_up` | #11 | notificar update |
| `in_transit` | #11 | notificar update **+ OTP-send** (D5) |
| `pod_submitted` | #13 | confirmar entrega (re-valida gates) |
| `otp_generated` | — | (no-op: auditoria only; OTP plaintext nunca no n8n, D5) |
| `delivered` / `cancelled` / `failed` / `expired` | #12 + #14 | notificar terminal + falhas |

Branches `no-op` existem porque o workflow correspondente é **encadeado** (n8n
encadeamento direto, não evento): #3←#2, #5←#4, #9←#8. Isso preserva o caminho feliz
da ADR-018 sem gerar loops (o evento que um workflow emite não re-dispara a si mesmo
porque o Switch não o mapeia a um sub-workflow).

### D3 — Timeout da rodada: n8n Wait node (durável, ≥65s) + reconciler backstop

- **Primário**: n8n **Wait node** agendado `response_window_seconds` após #5 abrir a
  rodada → dispara #8 ao expirar. Wait ≥65s é **durável** (sobrevive a restart do n8n
  na persistência do n8n, não em memória).
- **Backstop**: reconciler (D6) fecha rodadas `status='open' AND expires_at < now()`
  que o Wait perdeu (n8n crash/segfault/cron perdido). **Sem schema novo**
  (`expires_at` existe em 0023); sem `pg_cron`.
- Invariante: **≤1 close por rodada** garantido pelo guard `round_not_open` (RPC 0024),
  não pelo n8n. Wait e reconciler podem disparar #8 concorrentemente; o backend aceita
  só o primeiro.

### D4 — Auth: três fronteiras distintas, `service_role` nunca no n8n

| Fronteira | Mecanismo | Quem |
|---|---|---|
| Supabase → n8n (DB Webhook) | `httpHeaderAuth` (header secret próprio, **não** a internal-api-key) | n8n Webhook node valida header |
| n8n → backend (Route Handler) | `x-internal-api-key` (shared secret, ADR-019 D3) | handler `requireInternal` |
| backend → Supabase | `service_role` (system-client interno, **nunca** exposto) | só no backend |

- **`service_role` jamais no n8n/IA/DataCrazy/client** (regra mestra). O DB Webhook
  entrega só o registro `delivery_events` (auditoria, sem secrets); o n8n autentica-se
  ao backend por `x-internal-api-key`; o backend faz a mutação via system-client.
- O header do DB Webhook é um secret **separado** (`WEBHOOK_TO_N8N_SECRET`) — não
  reutilizar `INTERNAL_API_KEY` (sentido oposto: n8n→backend).

### D5 — OTP: n8n chama `/api/internal/notifications/send {type:'otp'}` (plaintext nunca no n8n)

- **n8n NÃO chama** `POST /api/internal/deliveries/{id}/otp`. Aquele endpoint gera o OTP
  (hash em `delivery_otps` + evento `otp_generated`) mas **redact `otp_code`** na
  response (ADR-021 D7 + fix Sessão 16: redact antes de `recordResult`, ledger sem
  plaintext). É superfície de **geração-only**, retida; o n8n não deve usá-la.
- O caminho legítimo é `POST /api/internal/notifications/send` com
  `{type:'otp', delivery_id}` (ADR-021 D2): o backend chama `generate_delivery_otp`
  **internamente**, monta a mensagem ao recebedor (`delivery_contact_phone`), envia via
  provider híbrido e loga em `notifications` — tudo sem expor o `otp_code` ao n8n.
  Response `{ok, reason}`; `notifications.payload` só metadados.
- Em #11 (`in_transit`), o dispatch OTP-send é: trigger `in_transit` →
  `notifications/send {type:'otp'}`. **O plaintext do OTP nunca transita pelo n8n.**
- R17: o `Idempotency-Key` do `notifications/send` é `{correlation}-{op}` (não
  `correlation_id`); dedup determinística em `notifications.idempotency_key`
  (`notif:otp:{delivery_id}`) + ledger.

### D6 — Reconciler: Schedule Trigger → `/api/internal/reconciler/scan` (read-only, state-based)

- n8n **Schedule Trigger** (cron) chama `POST /api/internal/reconciler/scan` (system,
  ADR-021 D5). O **backend** faz a query (read-only) e devolve achados de **estado
  preso**: (a) rodadas `open` com `expires_at < now()`; (b) drafts sem quote há >
  `stale_after_seconds`; (c) `searching_driver` sem rodada aberta.
- n8n **não query o DB direto** (regra mestra) — chama o endpoint e reprocessa cada
  achado via Route Handlers: (a)→#8, (b)→#3, (c)→#5/#9.
- **State-based, não event-based**: o reconciler não rastreia "qual evento o n8n
  processou"; procura **estado stuck** e reage. Isso sidestepa o problema de "evento
  perdido" do DB Webhook (pg_net tem fila de retry limitada): ainda que um POST ao n8n
  falhe com n8n down, o estado converge pelo scan periódico.
- Sem `Idempotency-Key` no scan (ledger `skip` → re-query sempre; cachear scan seria
  stale). As ações reprocessadas têm suas próprias chaves.

### D7 — Idempotência end-to-end (R17, ADR-018 D6 reforçado)

- Cada call n8n→backend leva `Idempotency-Key: {correlation_id}-{op}`
  (ex.: `corr-123-open_round`). **Nunca** usar `correlation_id` puro como
  `Idempotency-Key` (deduparia ops legítimas que compartilham correlation).
- `external_event_id` só para inbound reprocessado (webhook); `external_reference` só
  para criação (dedup em `delivery_requests`); `correlation_id` só propagação/log.
- Ledger `integration_events` (ADR-019 D4): claim/replay/in_flight/skip; release-on-throw
  para falhas transitórias (ADR-021 D2); `payload` NOT NULL respeitado com `{}` em
  endpoints sensitive (fix Sessão 16).

### D8 — Inbound é backend router, não n8n (D3 do usuário)

- #1 (nova solicitação), #7 (resposta de motorista) e #16 (webhook DataCrazy) são
  **roteados pelo backend** (`POST /api/webhooks/datacrazy`, ADR-020 D5:
  signature+dedup+route+200). O n8n **não** está no caminho inbound.
- O n8n reage a `delivery_events` (D1) e a chamadas explícitas (reconciler). Inbound
  vira `delivery_event` pela RPC (ex.: `delivery_created`), e **então** o DB Webhook
  dispara o workflow — não há path direto inbound→n8n.

### D9 — Logs sem secrets/PII (ADR-018 D8/D10)

- Logs do n8n: `correlation_id`, `delivery_request_id`, `event_type`, workflow, resultado.
- **Nunca** logar: `service_role`, `INTERNAL_API_KEY`, `WEBHOOK_TO_N8N_SECRET`,
  plaintext OTP, PII do cliente pré-atribuição. OTP é sensitive (ADR-019 D8); o
  `notifications/send` não loga o código (só metadados em `notifications.payload`).

## Consequências

- **ADR-018 D2 superseded**: Realtime → Database Webhooks. O design dos 16 workflows e
  o resto da ADR-018 íntegros. `N8N_WORKFLOWS.md` atualizado (modelo de trigger,
  tabela de endpoints, workflows #6/#10/#11/#12 → `notifications/send`, #8 reason
  `already_assigned`, #15 → `reconciler/scan`, #1/#7/#16 = backend router).
- **Provisionamento dev**: habilitar `pg_net` + criar Database Webhook (URL n8n) +
  criar credencial `httpHeaderAuth` no n8n + importar workflows via Public API —
  **Phase 2 live** (blocked em URL n8n + Public API key + versão, fornecidos pelo
  usuário). Não simulado.
- **Ressalvas (regra mestra)**: validação live do **trigger model** feita (ver seção
  "Validação live (Phase 2)"). Sub-workflows restantes + n8n→backend reachability + envio
  WhatsApp real → Phase 3. Geo `/quote`+`/enrich` 501 (Sessão 20). Storage RLS comportamental,
  UI, rate limiting/mTLS → Sessões 17-19/22/26. Envio WhatsApp real depende de credenciais
  Evolution/DataCrazy (D1 ADR-021) — Phase 3.

## Validação live (Phase 2 — 2026-08-31)

O usuário provisionou instância n8n (`https://n8n.processlabcorp.com.br/`) + Public API key.
**Não simulado** — tudo abaixo é execução real contra a instância e o dev Supabase.

1. **pg_net egress dev Supabase → n8n público**: habilitado `pg_net` (schema `net`);
   `net.http_post` ao echo workflow → n8n exec 209392 recebendo o body `{"hello":"from-pgnet"}`
   (`user-agent: pg_net/0.20.4`, confirmado no runData). Transporte provado.
2. **Dispatcher `VIO10-dispatcher`** (id `8M68aj7oExxijS73`): Webhook node (POST
   `/webhook/vio10-dispatcher`, `responseMode: onReceived` = ack 200 fire-and-forget, padrão
   robusto p/ DB trigger) → Code node valida `x-webhook-secret` (reject
   `invalid_webhook_secret`, exec 209410) + mapeia `event_type`→workflow (D2). Ping manual
   → exec 209409 `success`, route `{branch:'delivery_created', target_workflow:'#2-enrich'}`.
3. **DB trigger `trg_delivery_events_notify_n8n`** (AFTER INSERT `delivery_events`, função
   `notify_n8n_delivery_event` SECURITY DEFINER `set search_path=public,net` →
   `net.http_post` ao dispatcher c/ `x-webhook-secret`). **Infra de runtime, NÃO migration**
   (D1: provisão live via Management API, não `supabase/migrations` — o trigger não sobrevive
   a reset+replay, o que é desejável p/ manter a regressão determinística). Provado: INSERT
   real em `delivery_events` (service_role, FK válida) → trigger dispara → n8n exec c/
   `record.event_id` batendo **exato** com a row inserida:
   `delivery_created`→#2-enrich (209417), `delivered`→#12-terminal (209419),
   `otp_generated`→NOOP-chain (209420, ramo no-op correto), `round_closed`→#8-close (209421).
4. **Sub-workflow `VIO10-#2-enrich`** (id `zQsbwxwW9I8wD32L`): Webhook → HTTP Request
   (v4.2) → `http://localhost:3000/api/internal/deliveries/{{ $json.body.delivery_request_id }}/enrich`
   c/ headers `x-internal-api-key` (placeholder; `httpHeaderAuth` credential não criável via
   Public API — "type not a known type" — header literal usado; valor real é config-swap) +
   `Idempotency-Key: {corr}-enrich` (R17). Exec 209427: o request foi montado e disparado
   (**wiring provado** — URL template interpolada + headers) e errou `ECONNREFUSED`
   ("service refused the connection - perhaps it offline") = **gap honesto de
   reachability**: n8n roda num host público, o backend Next.js está em `localhost:3000` do
   dev (não alcançável do n8n). Os handlers backend já foram provados live via curl na
   Sessão 14-15; o único seam não-provado é a rede n8n→backend, que exige **tunnel** (ngrok/
   cloudflared) ou **deploy público** do Next.js — um problema de deployment, não de
   arquitetura. O ECONNREFUSED é o resultado correto e esperado enquanto o backend não é
   exposto.

**Conclusão Phase 2**: o mecanismo de reação a eventos (DB trigger → pg_net → n8n
dispatcher → roteamento por `event_type`) está **provado live**. O wiring n8n→backend
(HTTP Request + auth + URL template + Idempotency-Key) está **provado estruturalmente**;
a call live depende de reachability (Phase 3). `service_role` nunca no n8n (D4 íntegro); OTP
plaintext nunca transita pelo n8n (D5 — o enrich não toca OTP; o sub-workflow #11 future
usará `notifications/send {type:'otp'}`).

## Referências

- Supersede: `docs/adr/ADR-018-n8n-workflows.md` D2.
- Decisão usuário D3 (Sessão 16): `docs/plans/sessao-16-whatsapp-n8n.md`.
- Backend envia+loga / OTP nunca no n8n: `docs/adr/ADR-021-whatsapp-outbound-hybrid.md`
  D2/D7; fix redact-before-record + payload NOT NULL (Sessão 16).
- Reconciler scan: `lib/services/reconciler.ts`, ADR-021 D5.
- Handler pipeline + idempotency: `lib/api/internal-handler.ts`,
  `lib/idempotency/ledger.ts`, ADR-019 D1/D4.
- Webhook router inbound: `lib/api/webhook-handler.ts`, ADR-020 D5.
- `delivery_events` (auditoria canônica): migration 0002; 23 `delivery_event_type`
  (ADR-018 D2 verificado).
- Regra mestra: `CLAUDE.md`, `ARCHITECTURE.md:71-72`, ADR-018 D1.