# Plano — Sessão 16: WhatsApp outbound real + implementação n8n

> Plano executável em fases consecutivas (cada fase = um novo contexto de chat).
> Decisões trancadas com o usuário via `AskUserQuestion`. Baseado em Phase 0 — Documentation
> Discovery (3 subagentes, evidência nos arquivos do repositório + docs oficiais).

## Decisões trancadas (do usuário)

| # | Decisão | Escolha |
|---|---|---|
| D1 | Transporte WhatsApp outbound primário | **Híbrido**: DataCrazy nativo (`POST /conversations/{id}/messages`) quando há conversa aberta (janela 24h) + **fallback Evolution API V2** (`POST /message/sendText/{instance}`) p/ cold proactive (OTP ao recebedor, driver fora da janela) |
| D2 | Origem do envio + escrita em `notifications` | **Backend envia + loga**: novo `POST /api/internal/notifications/send` (system, `x-internal-api-key`). Backend resolve destinatário, escolhe provider, envia e insere/atualiza `notifications` (idempotente). Segredos do WhatsApp ficam no backend; n8n só dispara. |
| D3 | Arquitetura inbound (#16) | **Backend é o único entrypoint** (router já implementado Sessão 15: signature+dedup+route). n8n **não** está no caminho inbound — reage a eventos via **Supabase Database Webhooks** sobre `delivery_events`. Workflows #1/#7/#16 **deixam de ser workflows n8n** (são o router backend, já feito). |

## Phase 0 — Documentation Discovery (CONCLUÍDA)

### APIs permitidas (evidence-backed)

**Backend contract surface (já existe, Sessões 14-15):**
- 10 endpoints system/internal (`x-internal-api-key`, `service_role` interno) — ver `docs/N8N_WORKFLOWS.md` linhas 52-65 **MAS a tabela lá está STALE**; usar as rotas reais abaixo:
  - `POST /api/internal/deliveries` → `create_delivery_request`
  - `POST /api/internal/deliveries/{id}/enrich` → `GeocodingProvider.geocode` (**501 hoje**, Sessão 20)
  - `POST /api/internal/deliveries/{id}/quote` → `RoutingProvider.route` + `create_quote` (**501 hoje**)
  - `POST /api/internal/deliveries/{id}/confirm-quote` → `confirm_quote`
  - `POST /api/internal/deliveries/{id}/dispatch/rounds` → `open_dispatch_round`
  - `POST /api/internal/dispatch/rounds/{id}/close` → `select_winner_and_claim`
  - `POST /api/internal/deliveries/{id}/otp` → `generate_delivery_otp` (retorna plaintext `otp_code` — **sensitive**)
  - `POST /api/internal/deliveries/{id}/transitions` → `transition_delivery` (actor system)
  - `POST /api/internal/deliveries/{id}/confirm` → `confirm_delivery`
  - `POST /api/internal/offers/{id}/respond-link` → gera signed link (`{token, url, expires_at}`) — **pure, sem DB**
- 4 endpoints driver/user (cookie JWT, user-scoped):
  - `POST /api/offers/{id}/respond` (dual cookie-ou-token) → `respond_to_offer`
  - `POST /api/driver/availability` → `set_driver_availability`
  - `POST /api/driver/deliveries/{id}/pod` → `submit_proof_of_delivery`
  - `POST /api/driver/deliveries/{id}/transitions` → `transition_delivery` (actor driver)
- 1 webhook (HMAC `x-datacrazy-signature`): `POST /api/webhooks/datacrazy` → router (intents `new_request`/`offer_response`/`otp_request`/unknown→`routed_with_error`)

**Mapeamento reason→HTTP** (`lib/rpc/result.ts:14-62`): `ok:true`/`idempotent_replay`→200; `not_authorized`→403; `wrong_state`/`round_*`/`already_responded`/`invalid_transition`→409; `offer_expired`→410; `offer_not_found_for_driver`→404; `not_found`/`no_pricing_rule`/`pod_*`/`otp_*`→422; default→422; provider→501; `internal_error`→500. **`already_assigned`/`not_searching_driver`/`quote_expired`/`no_pending_quote` NÃO estão na tabela → 422.** n8n deve inspecionar `reason` no JSON body, não só o status HTTP.

**Signed link** (`lib/auth/signed-link.ts`): `base64url(payload).base64url(hmac)`, payload `{o,d,e,n}`, TTL 900s, IDOR `o===offerId`, timing-safe. Generator `POST /api/internal/offers/{id}/respond-link` (request `{driver_id, ttl_seconds?}`). Consumption em `/api/offers/{id}/respond` injeta `driver_id` do token, chama `respond_to_offer` system-scoped. **Não minta JWT** (o "signed link → JWT" do N8N_WORKFLOWS.md #7 é aspiracional).

**Idempotência**: `Idempotency-Key`/`x-external-event-id` → `integration_events` ledger (claim/replay→200/in_flight→409/skip). User-facing sem ledger (idempotência interna da RPC). Webhook dedup = `webhook_events`.

**WhatsApp outbound (novo):**
- DataCrazy nativo: `POST {DATACRAZY_API_BASE_URL}/api/v1/conversations/{conversationId}/messages`, `Authorization: Bearer {DATACRAZY_API_KEY}`, body `{body, isInternal:false}`. **HARD CONSTRAINT: sem endpoint p/ iniciar conversa com número novo** — só envia p/ conversa já aberta. Response `MessageDto.id` → `notifications.external_id`.
- Evolution API V2: `POST {EVOLUTION_API_URL}/message/sendText/{EVOLUTION_INSTANCE_NAME}`, header `apikey: {EVOLUTION_API_KEY}`, body `{"number":"55319...", "textMessage":{"text":"..."}}` (v2.3.7; se rejeitar, flat `{"number","text"}` — GitHub issue #2570). Envia p/ qualquer número, sem conversa prévia. Response `key.id` → `notifications.external_id`.
- 24h window (Meta): fora da janela, só template aprovado. **Evolution sidesteps** (texto livre, não-oficial). Cloud API exigiria templates (deferido).
- Action links: signed-link URL como **texto puro** no `body` (WhatsApp auto-detecta). Sem CTA-button template approval.
- Inbound ≠ outbound auth: inbound = HMAC `DATACRAZY_WEBHOOK_SECRET`; outbound = Bearer/apikey — **mecanismos diferentes**.

**n8n (novo):**
- HTTP Request node → Route Handlers, `httpHeaderAuth` credential (guarda `x-internal-api-key` criptografado via `N8N_ENCRYPTION_KEY`), **Never Error ON** + IF em `statusCode`. `Idempotency-Key` = `{correlation}-{op}` (nunca raw `correlation_id`).
- **Sem native Supabase Realtime trigger node.** Path master-rule-compliant = **Supabase Database Webhooks → n8n Webhook node** (um hook em `delivery_events` INSERT + Switch em `record.event_type`). Community `n8n-nodes-supabase-realtime` **rejeitado** (precisaria de `service_role` no n8n → viola regra mestra).
- Wait node: ≥65s durable (sobrevive restart), <65s in-memory (perdido). Reconciler DB-backstop **mandatório** (ADR-018 D3).
- Error Trigger workflow (#15) p/ DLQ. Schedule Trigger p/ reconciler cron.
- Execute Sub-workflow p/ chaining (#4→#5, #8→#9→#5, #2→#3).
- Self-host: Docker + Postgres + `N8N_ENCRYPTION_KEY` + reverse proxy. Workflows exportados como JSON.

### Discrepâncias/gaps descobertas (endereçadas no plano)
1. `notifications` existe (migration 0011) mas **nenhuma rota escreve nela** → Phase 1 cria o endpoint.
2. `superseded_by_concurrent_claim` **não é o reason retornado** pela SWAC — é `already_assigned` (422). n8n #8 key em `already_assigned`.
3. Tabela de endpoints do N8N_WORKFLOWS.md está **stale** vs código (driver pod/transitions são `/api/driver/...`, não `/api/internal/...`). Plano usa rotas reais.
4. #16 inbound ambíguo → resolvido por D3: backend é entrypoint, n8n fora do inbound.
5. Geo `/enrich`+`/quote` = 501 até Sessão 20 → caminho feliz #2/#3 não completa end-to-end live (esperado, não simular).
6. `service_role` **nunca** no n8n (CLAUDE.md, ARCHITECTURE.md:71-72, ADR-020:168). n8n autentica só via `x-internal-api-key`.

---

## Pré-requisitos a resolver antes de iniciar (bloqueantes)

- **P1. Confirmar/abilitar Supabase Database Webhooks** no projeto dev (`pg_cron`+`pg_net`; default em Supabase cloud, precisa habilitar em self-hosted/dev). Verificar `delivery_events` na publication `supabase_realtime`.
- **P2. Provisionar instância Evolution API V2** (ou confirmar acesso a uma) + instância DataCrazy conectada ao número WhatsApp ViO10. **Atenção two-number**: DataCrazy e Evolution tipicamente conectam números WhatsApp diferentes (um número só pode ter um provider ativo). P/ o híbrido, ou (a) dois números ViO10 (um DataCrazy conversacional, um Evolution proactive — receptor/driver vê dois remetentes), ou (b) simplificar p/ **Evolution p/ todo outbound** + DataCrazy/Crazy IA só no inbound (agente de pedidos). **Decisão de config na Phase 1** — o provider abstraction torna isso swapável.
- **P3. Obter `DATACRAZY_API_KEY`** (painel `crm.datacrazy.io/config/api`, mostrada 1x) + `EVOLUTION_API_KEY`/`EVOLUTION_INSTANCE_NAME`. Definir no `.env` (server-only).
- **P4. Provisionar n8n self-hosted** (Docker) — ver Phase 2.

---

## Phase 1 — Backend: provider WhatsApp outbound + endpoint de notificação

**Objetivo:** o backend passa a ser o único que envia WhatsApp e loga em `notifications`. n8n (Phase 2) só chama um endpoint.

### O que implementar (COPY dos padrões existentes)

1. **Migration 0029 — `whatsapp_conversations`** (schema prep, sem funções):
   - Tabela `whatsapp_conversations(phone text PK-normalizada, conversation_id text, provider text, window_expires_at timestamptz, last_inbound_at timestamptz, updated_at timestamptz)`; unique `(phone)`.
   - RLS default-deny; grants: `service_role` DML, `authenticated` nenhum. Copiar padrão de `0011_integrations_notifications_pod.sql:40-59`.
   - **Por que:** captura `conversation_id`+janela de cada inbound DataCrazy p/ o híbrido (D1) decidir DataCrazy-vs-Evolution no outbound.

2. **Provider abstraction** — COPY do padrão geo (`lib/services/geo.ts:8` `ProviderNotConfiguredError` + `lib/providers/routing-provider.ts` registry vazio):
   - `lib/providers/whatsapp-provider.ts`: interface `WhatsAppProvider.send({to, body, conversationId?}): Promise<{ok, externalId, channel}>` + registry + `ProviderNotConfiguredError` (501 se nenhum provider configurado).
   - `lib/providers/datacrazy-provider.ts`: `POST {DATACRAZY_API_BASE_URL}/api/v1/conversations/{conversationId}/messages`, Bearer `DATACRAZY_API_KEY`, body `{body, isInternal:false}`. **Exige `conversationId`** (resolve de `whatsapp_conversations` se `window_expires_at > now()`). Retorna `externalId = MessageDto.id`.
   - `lib/providers/evolution-provider.ts`: `POST {EVOLUTION_API_URL}/message/sendText/{EVOLUTION_INSTANCE_NAME}`, header `apikey`, body nested `{"number","textMessage":{"text"}}` (fallback flat se rejeitar). Cold proactive por phone. Retorna `externalId = key.id`.
   - **Roteamento híbrido (D1)**: se `whatsapp_conversations` tem linha fresca (`window_expires_at > now()`) p/ o phone → DataCrazy (usa `conversation_id`); senão → Evolution. Provider abstraction swapável (resolve P2 sem reescrever).

3. **Service `lib/services/notifications.ts`** — `sendNotification(client, input, correlationId)`:
   - Resolve destinatário: `recipient_role='driver'` → `drivers.phone` (join); `recipient_role='receiver'` → `delivery_requests.delivery_contact_phone`; `recipient_role='business'` → `businesses.*`/contacto.
   - Resolve `conversationId` de `whatsapp_conversations` (phone).
   - Escolhe provider (híbrido D1). Envia. Upsert em `notifications` (`idempotency_key` UNIQUE, `channel`, `provider`, `external_id`, `status`, `attempts`, `payload`, `recipient_driver_id`/`recipient_user_id`). Idempotência por `notifications.idempotency_key` (replay → no-op 200).
   - **PII rules (ADR-018 D10)**: mensagem de oferta (`type:'offer'`) **sem PII do cliente** antes da atribuição; mensagem de atribuição (`type:'assignment'`) libera PII (endereços/contatos).

4. **Route Handler `POST /api/internal/notifications/send`** (system, `x-internal-api-key`, idempotency ledger `withIdempotency`):
   - Body: `{type: 'offer'|'otp'|'assignment'|'status_update'|'terminal', offer_id?, delivery_id?, correlation_id?}`.
   - `type:'offer'` → resolve offer+delivery+driver; **gera signed link** via `createActionLink` (`lib/auth/signed-link.ts:67`, TTL = `response_window_seconds`); monta mensagem sem PII; envia; loga.
   - `type:'otp'` → chama `generate_delivery_otp` **internamente** (plaintext `otp_code` NÃO sai do backend); monta mensagem OTP p/ `delivery_contact_phone`; envia; loga. Response `{ok, reason}` **sem `otp_code`**.
   - `type:'assignment'|'status_update'|'terminal'` → resolve+template+envia+loga.
   - COPY do handler pipeline `handleInternalPost` (`lib/api/internal-handler.ts:24`).
   - **OTP plaintext nunca logado** (ADR-018 D8); `notifications.payload` guarda só metadados (correlation, type, recipient_role), nunca o código.

5. **Estender inbound webhook handler** (`lib/api/webhook-handler.ts`) p/ capturar `conversation_id`+phone+timestamp do payload DataCrazy → upsert `whatsapp_conversations` (`window_expires_at = now + 24h`). Confirmar nomes dos campos do payload DataCrazy inbound (pegar de uma chamada real ou docs).

6. **Endpoint reconciler read** `POST /api/internal/reconciler/scan` (system) — retorna stale: (a) `dispatch_rounds status='open' AND expires_at<now()`; (b) drafts sem quote; (c) `searching_driver` sem rodada aberta. **Read-only via `service_role`** (n8n não query DB direto). Sem mutação.

7. **`.env.example`** — adicionar: `DATACRAZY_API_KEY`, `DATACRAZY_API_BASE_URL`, `EVOLUTION_API_URL`, `EVOLUTION_API_KEY`, `EVOLUTION_INSTANCE_NAME`. (Cloud API/templates `WHATSAPP_*` **deferidos** — Evolution não precisa.)

8. **ADR-021** — WhatsApp outbound: provider abstraction híbrido (D1), backend-envia-e-loga (D2), `notifications` writer, OTP plaintext nunca sai do backend, sem PII pré-atribuição, `whatsapp_conversations` capture, reconciler read endpoint.

### Doc references (COPY destes locais)
- Padrão provider + 501: `lib/services/geo.ts:8-11`, `lib/providers/routing-provider.ts`, `lib/api/internal-handler.ts:67-72`
- Handler pipeline system: `lib/api/internal-handler.ts:24`
- Idempotency ledger: `lib/idempotency/ledger.ts:134`
- Signed link gen: `lib/auth/signed-link.ts:67-89`; endpoint `app/api/internal/offers/[id]/respond-link/route.ts:13`
- `notifications` schema: `supabase/migrations/0011_integrations_notifications_pod.sql:40-59`
- Service layer pattern: `lib/services/deliveries.ts`, `lib/services/dispatch.ts`
- Webhook handler (estender): `lib/api/webhook-handler.ts:25`

### Verification checklist
- [ ] `tsc --noEmit` clean
- [ ] vitest: providers mockados (DataCrazy + Evolution), roteamento híbrido (fresco→DataCrazy, expirado→Evolution), idempotência `notifications.idempotency_key` (replay→200), OTP plaintext ausente do response E do `notifications.payload`
- [ ] Regressão DB 10/10 suítes PASS (zero regressão — nada toca RPCs existentes)
- [ ] Live: reset+replay 0001→0029 limpo (29/29); inventário: 28 tabelas (+`whatsapp_conversations`), RLS, grants
- [ ] Live curl `POST /api/internal/notifications/send` `{type:'offer', offer_id}` com `x-internal-api-key` → 200 + mensagem enviada (Evolution test number) + row em `notifications` (verificar via Management API); sem key → 401 fail-closed; replay mesmo `Idempotency-Key` → 200 mesmo id, 0 duplicação
- [ ] Live curl `{type:'otp', delivery_id}` → 200 **sem `otp_code`** no response; `delivery_otps` tem hash; `notifications` logado sem plaintext
- [ ] Confirmar: `notifications` agora é escrito (grep `.from("notifications")` em `lib/` retorna inserts)
- [ ] Sem `service_role` vazando ao n8n (n8n não existe ainda nesta phase)

### Anti-pattern guards
- ❌ NÃO usar `correlation_id` como `Idempotency-Key` (propaga end-to-end; deduparia ops legítimas). Use `{correlation}-{type}-{id}`.
- ❌ NÃO retornar `otp_code` do endpoint `/notifications/send` (plaintext fica no backend).
- ❌ NÃO logar plaintext do OTP em `notifications.payload` nem em logs.
- ❌ NÃO colocar PII do cliente na mensagem `type:'offer'` (pré-atribuição).
- ❌ NÃO inventar endpoint DataCrazy "criar conversa" (não existe — use Evolution p/ cold).
- ❌ NÃO fazer n8n escrever em `notifications` (master rule) — só o backend.

---

## Phase 2 — n8n: provisionamento + trigger model + caminho feliz

**Objetivo:** n8n self-hosted rodando, recebendo Database Webhooks de `delivery_events`, e executando o caminho feliz (#2→#3→#4→#5→#6→#8→#10→#11→#13) chamando os Route Handlers via `x-internal-api-key`.

### O que implementar (COPY dos padrões n8n carregados nas skills)

1. **Provisionar n8n** (Docker + Postgres + `N8N_ENCRYPTION_KEY` + reverse proxy Caddy/Nginx, porta 127.0.0.1:5678). **Pin de versão n8n** + documentar a restrição 65s do Wait node (reconciler cobre). `GENERIC_TIMEZONE=America/Sao_Paulo`.
2. **Credential `httpHeaderAuth`** "Backend Internal API Key" = `{name:"x-internal-api-key", value:<INTERNAL_API_KEY>}`. **NUNCA** `service_role` no n8n (master rule). NUNCA colar o secret no JSON do workflow.
3. **Supabase Database Webhook** em `delivery_events` INSERT → n8n Webhook node (path unguessable). Habilitar `pg_cron`/`pg_net` (P1). Verificar `delivery_events` em `supabase_realtime` publication.
4. **Trigger router**: um Webhook node + **Switch em `{{$json.body.record.event_type}}`** → Execute Sub-workflow por workflow. (Supabase Database Webhooks = um hook por tabela, não por event_type — Switch é o padrão realista.)
5. **Workflows caminho feliz** (cada um workflow separado, observável/versionável — ADR-018 D7):
   - **#2 enrich** — react `delivery_created` → `POST /api/internal/deliveries/{id}/enrich` (**501 hoje** — n8n trata 501 como "esperar Sessão 20", não como erro fatal).
   - **#3 quote** — chain de #2 → `POST /api/internal/deliveries/{id}/quote` (501 hoje).
   - **#4 dispatch start** — react `dispatch_started` (emitido por `confirm_quote`) → inicializa round-1 params (constantes/env n8n) → Execute Sub-workflow #5.
   - **#5 open round** — Execute Sub-workflow Trigger (de #4/#9) → `POST /api/internal/deliveries/{id}/dispatch/rounds` (body `search_radius_m, max_candidates, driver_offer_cents, response_window_seconds`). `Idempotency-Key={correlation}-round-open`. Never Error ON + IF statusCode. `candidate_count>0` → #6 (por offer) **+ agenda Wait node**; `==0` → #8 imediato.
   - **#6 send offers** — react `offer_created` → `POST /api/internal/notifications/send` `{type:'offer', offer_id}` (backend resolve signed link + envia + loga). `Idempotency-Key={correlation}-offer-{offer_id}`.
   - **#8 timeout/close** — Wait node (`afterTimeInterval`, `amount={{$json.response_window_seconds}}`) **primário** → `POST /api/internal/dispatch/rounds/{id}/close`. Key reason em **`already_assigned`**/`no_candidates`/`won` (NÃO `superseded_by_concurrent_claim`). `won`→#10; `no_candidates`→#9; `already_assigned`/`round_not_open`→no-op.
   - **#10 assignment** — react `driver_assigned` → `POST /api/internal/notifications/send` `{type:'assignment', delivery_id}` (PII liberada).
   - **#11 updates** — react `driver_to_pickup`/`at_pickup`/`picked_up`/`in_transit`. Em `in_transit` → `POST /api/internal/notifications/send` `{type:'otp', delivery_id}` (backend gera OTP + envia ao recebedor; plaintext nunca no n8n). Demais → `POST /api/internal/notifications/send` `{type:'status_update', delivery_id}`.
   - **#13 delivery confirm** — react `pod_submitted` (metadata `pod_type='delivery'`) → `POST /api/internal/deliveries/{id}/confirm` `{geo_tolerance_m?}`.
6. **Exportar workflows** como JSON p/ `n8n/workflows/*.json` (versionado no repo).

### Doc references (COPY destes locais)
- HTTP Request + httpHeaderAuth + Never Error: n8n skill `n8n-node-configuration` + `n8n-workflow-patterns`; endpoint bodies em `lib/services/dispatch.ts:6-13`, `app/api/internal/dispatch/rounds/[id]/close/route.ts:20-25`, `app/api/internal/deliveries/[id]/otp/route.ts:20-21`
- Headers: `x-internal-api-key` (`lib/supabase/internal-auth.ts:28`), `Idempotency-Key`/`x-external-event-id` (`lib/api/http.ts:34-36`), `x-correlation-id` (`lib/api/http.ts:23`)
- reason→status: `lib/rpc/result.ts:14-62`
- Workflow design base: `docs/N8N_WORKFLOWS.md` #2/#3/#4/#5/#6/#8/#10/#11/#13 (linhas 128-410) — **usar rotas reais, não a tabela stale linhas 52-65**
- Wait node 65s/backstop: `docs/N8N_WORKFLOWS.md` D3 (linhas 38-44)
- Master rule service_role: `ARCHITECTURE.md:71-72`, `CLAUDE.md`

### Verification checklist
- [ ] n8n saudável (healthcheck); credential criptografada no store; workflow JSON não contém secrets (grep)
- [ ] Database Webhook dispara ao inserir em `delivery_events` (teste: insert manual → n8n recebe)
- [ ] Switch roteia por `event_type` ao sub-workflow certo
- [ ] HTTP Request ao backend com `x-internal-api-key` → 200; sem key → 401 (n8n loga, não crasha)
- [ ] `Idempotency-Key={correlation}-{op}` — replay retorna 200 mesmo id, 0 duplicação no `integration_events`
- [ ] #5: `candidate_count>0` agenda Wait; #8 fecha rodada → `won`→`assigned` (verificar 1 assignment ativa no DB) ou `no_candidates`→#9
- [ ] #6: mensagem enviada (Evolution test number) + row em `notifications` + signed link no corpo (sem PII cliente)
- [ ] #11 `in_transit`: `notifications` row `type:'otp'` sem plaintext no `payload`; `delivery_otps` com hash
- [ ] **Ressalva**: #2/#3 retornam 501 (geo provider Sessão 20) — caminho feliz não completa end-to-end live; validar o **wiring n8n** com evento manual ou stub, NÃO simular PASS do geo
- [ ] Workflows exportados em `n8n/workflows/*.json`

### Anti-pattern guards
- ❌ NÃO armazenar `service_role` no n8n (master rule). NÃO usar community `n8n-nodes-supabase-realtime` (precisaria).
- ❌ NÃO fazer n8n chamar SQL/Postgres direto (`n8n-nodes-base.postgres`) p/ mutação — só Route Handlers.
- ❌ NÃO fazer n8n decidir atribuição — só `select_winner_and_claim` (backend) decide.
- ❌ NÃO usar `correlation_id` como `Idempotency-Key`.
- ❌ NÃO logar OTP plaintext em Code nodes do n8n (n8n #11 não vê o código — backend envia direto).
- ❌ NÃO contar só com o Wait node p/ timeout — reconciler (Phase 3) é mandatório.
- ❌ NÃO simular PASS do geo (501 é real).

---

## Phase 3 — n8n: falhas, retry/DLQ, reconciler, novas rodadas

**Objetivo:** caminhos de falha, novas rodadas e o backstop que garante convergência mesmo com n8n down.

### O que implementar

1. **#9 nova rodada** — chain de #8 `no_candidates`: se `round_number < max_rounds` (const n8n) → calcula próximos params (raio maior, offer talvez maior) → Execute Sub-workflow #5; senão → `POST /api/internal/deliveries/{id}/transitions` `{to_status:'expired'}` (system). Guard: se corrida já `assigned` (concorrente) → no-op.
2. **#14 falhas** — react `cancelled`/`failed`/`expired`/`assignment_superseded` + invocado por outros em erro: classifica; se não-terminal, `POST /api/internal/deliveries/{id}/transitions` (system, `metadata.reason`); notifica business/admin via `POST /api/internal/notifications/send` `{type:'terminal'}`.
3. **#15 retry/DLQ + reconciler**:
   - **Error Trigger workflow** (bound como Error Workflow em todos os 16): classifica (429/502/503→retry backoff; 401/404/schema→DLQ; idempotência conflito→reconcile). Max 3-5 retries com jitter; após N → DLQ + alerta (#12). Reusa o mesmo `Idempotency-Key` nos retries (backend replay→200).
   - **Schedule Trigger** (e.g. 5 min) reconciler: `POST /api/internal/reconciler/scan` (Phase 1) → p/ cada achado reprocessa: (a) round expirado → `POST /api/internal/dispatch/rounds/{id}/close`; (b) draft sem quote → #3; (c) `searching_driver` sem rodada → #5/#9. Idempotente via estado + `external_event_id`.
4. **DLQ**: após N retries → dead-letter + alerta humano (notifica admin via `POST /api/internal/notifications/send`).

### Doc references
- Error Trigger pattern: n8n skill `n8n-validation-expert` + `n8n-workflow-patterns`; `docs/N8N_WORKFLOWS.md` #14/#15 (linhas 416-458)
- Reconciler achados: `docs/N8N_WORKFLOWS.md` D2 (linhas 29-36), #15 (linhas 435-458)
- `expires_at` já existe em `dispatch_rounds` (migration 0023) — sem schema novo
- Transition terminal: `app/api/internal/deliveries/[id]/transitions/route.ts:24`

### Verification checklist
- [ ] Matar n8n mid-Wait (kill container) → reconhecer → reconciler fecha a rodada expirada via `/dispatch/rounds/{id}/close` (verificar `status='closed'` no DB)
- [ ] #8 `no_candidates` → #9 → #5 abre nova rodada (raio maior); `max_rounds` exaurido → `expired` no DB
- [ ] Falha repetida (forçar 5xx) → Error Trigger → retries com backoff → após N → DLQ + alerta admin
- [ ] Reconciler idempotente: rodada já fechada → re-close → `round_not_open` (no-op, não duplica)
- [ ] Corrida já `assigned` quando #9 roda → no-op (não abre rodada sobreposta)

### Anti-pattern guards
- ❌ NÃO usar `pg_cron` novo (reconciler é n8n Schedule Trigger, não DB cron — ADR-018 D3).
- ❌ NÃO reprocessar sem `Idempotency-Key`/`external_event_id` (duplicaria efeito).
- ❌ NÃO fazer reconciler mutar direto — só chama Route Handlers.

---

## Phase 4 — ADRs + docs + registro + regressão final

### O que fazer
1. **ADR-021** (WhatsApp outbound, Phase 1) + **ADR-022** (n8n implementação: trigger model Database Webhooks, Wait+backstop, backend-envia-e-loga, #16=backend não n8n, reconciler read endpoint, service_role nunca no n8n).
2. **Atualizar `docs/N8N_WORKFLOWS.md`**:
   - Corrigir tabela stale de endpoints (linhas 52-65) → rotas reais (`/api/driver/deliveries/{id}/pod` cookie JWT; `/api/driver/.../transitions`; `/api/internal/notifications/send` novo; `/api/internal/reconciler/scan` novo).
   - Corrigir #8: reason `already_assigned` (não `superseded_by_concurrent_claim`).
   - Marcar #1/#7/#16 como **backend router** (não n8n workflow) — n8n reage aos eventos que esses emitem.
   - Adicionar os 2 novos endpoints à contract surface.
3. **Atualizar `docs/DATACRAZY_INTEGRATION.md`**: outbound híbrido (DataCrazy+Evolution), 24h window, capture de conversation_id, Evolution sidesteps templates, PII rules, OTP plaintext só no backend.
4. **Atualizar** `BACKEND.md` (§ notifications/whatsapp), `ARCHITECTURE.md` (§ n8n/whatsapp), `PLAN.md` (Sessão 16 status), `CHANGELOG.md`, `CODE_REVIEW.md`.
5. **Regressão final**: DB 10/10 suítes PASS (418+ asserções, pós reset+replay 0001→0029) + vitest (124+ novos) + live vertical slice completo (create→...→delivered onde o geo permitir; onde 501, declarar ressalva).
6. **Registro final** em `N8N_WORKFLOWS.md` (ID/nome/função de cada workflow provisionado, credenciais referenciadas sem secrets, versão n8n pin).

### Verification checklist
- [ ] ADR-021 + ADR-022 em `docs/adr/`
- [ ] N8N_WORKFLOWS.md consistente com código (rotas reais, reasons reais, #1/#7/#16=backend)
- [ ] Regressão DB 10/10 + vitest tudo PASS
- [ ] Live vertical slice documentado (com ressalvas explícitas)

---

## Anti-patterns cross-cutting (NÃO fazer em nenhuma phase)

- ❌ n8n/IA/DataCrazy escrever no DB direto (master rule) — só via Route Handler.
- ❌ `service_role` fora do backend (n8n, IA, DataCrazy, client).
- ❌ n8n decidir atribuição/preço/ETA/status — backend decide (SWAC, create_quote, etc.).
- ❌ Misturar idempotency keys (R17): `Idempotency-Key`≠`external_event_id`≠`external_reference`≠`correlation_id`.
- ❌ Logar OTP plaintext ou `service_role` em qualquer camada.
- ❌ Expor PII do cliente antes da atribuição.
- ❌ Simular PASS (regra mestra) — geo 501 é real; Storage/n8n/WhatsApp live só quando provisionado.
- ❌ Wait node como único timeout (reconciler mandatório).
- ❌ Inventar endpoint DataCrazy "criar conversa" (não existe).

## Ressalvas (declarado, não PASS — Sessões futuras)

- **Geo provider** (`/enrich`+`/quote` 501) → Sessão 20. Caminho feliz n8n não completa end-to-end live; valida-se o wiring com evento manual.
- **WhatsApp Cloud API templates** (Meta approval) → deferido; Evolution (texto livre) cobre o MVP. Cloud API oficial p/ produção → decisão futura.
- **Storage RLS comportamental** → Sessões 17-19.
- **UI PWA/dashboards/portal** → Sessões 17-19.
- **Rate limiting/mTLS/rotação** → Sessão 22/26.
- **two-number outbound** (DataCrazy + Evolution = 2 números WhatsApp) → decisão de config/produto; provider abstraction permite consolidar em 1 (Evolution p/ todo outbound) sem reescrever.