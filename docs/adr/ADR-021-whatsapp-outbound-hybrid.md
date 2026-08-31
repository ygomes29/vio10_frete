# ADR-021 — WhatsApp outbound híbrido: provider abstraction, backend-envia-e-loga, reconciler scan

- **Status**: Aprovado
- **Data**: 2026-08-31
- **Sessão**: 16

## Contexto

A Sessão 15 (ADR-020) fechou a contract surface driver/user + webhook router inbound
(`POST /api/webhooks/datacrazy`, signature+dedup+route). A ressalva explícita era:
**WhatsApp outbound real** (envio de ofertas/OTP/status via link assinado) + a
implementação n8n (workflows ADR-018 consumindo os Route Handlers) ficavam para a
Sessão 16. Junto, o `notifications` (migration 0011) existia desde a Sessão 03 mas
**nenhuma rota escrevia nele** — gap descoberto no Phase 0 do plano.

A regra mestra (CLAUDE.md, ARCHITECTURE.md:71-72, ADR-020:168) é inegociável: **n8n e
DataCrazy não escrevem no banco nem enviam WhatsApp direto**. Eles chamam o backend.
`service_role` nunca vaza ao n8n/IA/DataCrazy/client. Esta ADR define a camada de
**outbound** que materializa isso: o backend é o único que envia WhatsApp e loga em
`notifications`; o n8n (Sessão 16 Phase 2) só dispara um endpoint.

### Decisões do usuário (AskUserQuestion — Phase 0 do plano)

- **D1 — Transporte outbound híbrido**: DataCrazy nativo (`POST /conversations/{id}/messages`)
  quando há conversa aberta (janela 24h) + **fallback Evolution API V2**
  (`POST /message/sendText/{instance}`) p/ cold proactive (OTP ao recebedor, driver fora
  da janela).
- **D2 — Backend envia + loga**: novo `POST /api/internal/notifications/send` (system,
  `x-internal-api-key`). Backend resolve destinatário, escolhe provider, envia e insere
  em `notifications` (idempotente). Segredos do WhatsApp ficam no backend; n8n só dispara.
- **D3 — Backend é o único entrypoint inbound**: o router Sessão 15 (signature+dedup+route)
  é o entrypoint; n8n **não** está no caminho inbound — reage a eventos via Supabase
  Database Webhooks sobre `delivery_events` (Phase 2).

## Decisões

### D1 — Provider abstraction híbrido (COPY do padrão geo ADR-005)

- `lib/providers/whatsapp-provider.ts`: interface `WhatsAppProvider.send({to, body,
  conversationId?}) → {ok, externalId, channel:'whatsapp', provider}` + registry
  (`registerWhatsAppProvider`/`getWhatsAppProvider`/`isWhatsAppAvailable`/`resetWhatsAppProvider`)
  + `WhatsAppProviderNotConfiguredError { reason:'whatsapp_provider_not_configured',
  status:501 }`. Sem provider registrado → 501 (mesma semântica do geo, ADR-019 D5).
- `lib/providers/datacrazy-provider.ts`: `POST {DATACRAZY_API_BASE_URL}/api/v1/conversations
  /{conversationId}/messages`, `Authorization: Bearer {DATACRAZY_API_KEY}`, body
  `{body, isInternal:false}`, response `MessageDto.id` → `externalId`. **Exige
  `conversationId`** (HARD CONSTRAINT: DataCrazy não inicia conversa com número novo).
  Outbound ≠ inbound: outbound é Bearer, inbound é HMAC (mecanismos diferentes).
- `lib/providers/evolution-provider.ts`: `POST {EVOLUTION_API_URL}/message/sendText/
  {EVOLUTION_INSTANCE_NAME}`, header `apikey`, body nested `{number, textMessage:{text}}`
  (v2.3.7) **com fallback flat** `{number, text}` em 400/422 (GitHub issue #2570). Cold
  proactive por phone. Response `key.id` → `externalId`.
- `lib/providers/hybrid-whatsapp-provider.ts`: roteamento D1 — `conversationId` explícito
  → DataCrazy; senão resolve conversa do phone: fresca (`window_expires_at > now()`) +
  DataCrazy → DataCrazy; senão + Evolution → Evolution (cold); stale + só DataCrazy →
  DataCrazy (tenta); nenhum → 501. `resolveConversation` injetado (testabilidade).
- `lib/providers/whatsapp-registration.ts`: `ensureWhatsAppProviderRegistered()` idempotente
  — lê env, registra o híbrido (service_role interno, nunca vaza). Sem env → nada → 501.
- **Erros sanitizados**: providers lançam `datacrazy_send_failed:<status>` /
  `evolution_send_failed:<status>` (só status HTTP, sem body p/ não vazar
  PII/conversationId em logs). Segredos (`apiKey`) nunca logados.

### D2 — Backend envia + loga em `notifications` (n8n só dispara)

- `POST /api/internal/notifications/send` (system, `x-internal-api-key`, ADR-019 D1
  pipeline `handleInternalPost` + `withIdempotency` ledger). Body:
  `{type:'offer'|'otp'|'assignment'|'status_update'|'terminal', offer_id?, delivery_id?}`.
- `lib/services/notifications.ts` — `sendNotification(client, input, correlationId)`:
  resolve destinatário, escolhe provider (híbrido D1), envia, upsert em `notifications`.
  - **offer** → resolve offer+driver+delivery; **gera signed link** via `createActionLink`
    (TTL = restante até `delivery_offers.expires_at`, clamp 60..900); mensagem **sem PII
    do cliente** (pré-atribuição — ADR-018 D10); envia ao driver (`drivers.phone`).
  - **otp** → chama `generate_delivery_otp` **internamente** (plaintext `otp_code` fica no
    backend); monta mensagem ao recebedor (`delivery_contact_phone`); envia; **response
    `{ok, reason}` sem `otp_code`**; `notifications.payload` só metadados (correlation,
    type, recipient_role) — **nunca o código OTP**.
  - **assignment** → resolve assignment ativa + PII (pós-atribuição: endereços/contatos
    liberados); envia ao driver.
  - **status_update**/**terminal** → envia ao contato de coleta (`pickup_contact_phone`).
- **Idempotência em duas camadas**: handler ledger (`withIdempotency` por `Idempotency-Key`)
  + `notifications.idempotency_key` determinística (`notif:{type}:{offer_id|delivery_id}[:{status}]`,
  UNIQUE, upsert `onConflict:idempotency_key` + `ignoreDuplicates`). **NÃO usar
  `correlation_id` como `Idempotency-Key`** (R17 — propaga end-to-end; deduparia ops
  legítimas). n8n deve usar `{correlation}-{op}`.
- **release-on-throw (fix Sessão 16, validação live)**: `withIdempotency` foi
  endurecido — quando `fn()` **lança** (provider 501 `whatsapp_provider_not_configured`,
  5xx do Evolution/DataCrazy), a claim é **deletada** (`releaseClaim`) e a exceção
  propaga, em vez de deixar a row `pending` para sempre. Sem isso, o retry com o mesmo
  `Idempotency-Key` caía em `in_flight` → 409, envenenando a chave para falhas
  transitórias e bloqueando a retomada do n8n após provisionamento/recuperação. Distinção
  preservada: **lança = transitório/retryable** (claim liberada), **retorna RpcResult
  `{ok:false,reason}` = terminal/replayable** (gravado por `recordResult` e replayed —
  `wrong_state`/`not_found`/`invalid_*`). Provado live: retry com mesma chave após 501
  re-executa (501, não 409), `integration_events` vazio. Testes: +2 em `ledger.test.ts`.
- **payload NOT NULL (fix Sessão 16, validação live)**: `handleInternalPost` passa
  `payload: opts.sensitive ? null : body` (endpoints sensitive não logam body/PII —
  ADR-019 D8). Mas `integration_events.payload` é **NOT NULL** (default `'{}'::jsonb`,
  migration 0011). Enviar `null` faz a `upsert` falhar **silenciosamente** (erro em
  `.error`, `ins.data=null` — supabase-js não lança) → `claimIdempotency` cai no recheck
  → fallback `skip` → **sem idempotência**. Sintoma live: endpoint OTP (`sensitive`)
  nunca gravava row no ledger, `integration_events` sempre `[]` — descoberto ao provar
  o redact-on-replay. Fix: `insertRow.payload = opts.payload ?? {}` (objeto vazio
  respeita a coluna sem vazar PII). Provado live: após fix, OTP com `Idempotency-Key`
  → `integration_events` `status:'processed'`, replay (segunda call mesma key) **não
  re-executa** (`otp_generated` +1, não +2). Testes: +2 em `ledger.test.ts`
  (payload null → `{}`, payload explícito → preservado).
- **service_role** interno (system-client) — nunca vaza ao n8n/IA/DataCrazy/client.

### D3 — `notifications` aceita destinatário externo (recebedor)

- Migration **0029** adiciona `notifications.recipient_phone text` e relaxa o CHECK
  `notifications_at_least_one_recipient_chk` p/ `(recipient_user_id IS NOT NULL OR
  recipient_driver_id IS NOT NULL OR recipient_phone IS NOT NULL)`. Necessário porque o
  OTP/status ao recebedor usam `delivery_contact_phone` (externo, sem user/driver
  cadastrado). service_role já tem DML full (0015:33); authenticated mantém SELECT sob
  RLS (policy `notif_sel` 0017 não referencia a coluna — linhas phone-only têm user/driver
  null → só admin lê, default-deny p/ demais).

### D4 — `whatsapp_conversations` (capture do inbound p/ roteamento outbound)

- Migration **0029** cria `whatsapp_conversations(phone text UNIQUE, conversation_id text,
  provider text, window_expires_at timestamptz, last_inbound_at timestamptz, updated_at)`.
  RLS default-deny (nenhuma policy); grants: `service_role` all; authenticated/anon nada
  (PII: phone + conversation_id). Writes só via backend (service_role).
- `lib/api/webhook-conversation-capture.ts`: cada inbound DataCrazy faz upsert
  (`window_expires_at = now + 24h`, `provider='datacrazy'`). Hook
  `captureConversation` adicionado ao `WebhookHandlerOpts` (best-effort, antes do
  roteamento, não derruba o intent). **Ressalva**: nomes exatos dos campos do payload
  inbound DataCrazy a confirmar live (extração defensiva tenta vários paths).

### D5 — Reconciler scan (read-only) — backend faz a query, n8n chama o endpoint

- `POST /api/internal/reconciler/scan` (system, ADR-019 D1 pipeline). **Read-only**,
  sem `Idempotency-Key` (ledger `skip` → re-query sempre; cachear scan seria stale).
  Retorna achados stale: (a) `dispatch_rounds status='open' AND expires_at<now()`;
  (b) drafts sem quote há > `stale_after_seconds` (default 300); (c) `searching_driver`
  sem rodada aberta. n8n (Schedule Trigger, Phase 3) chama e reprocessa cada achado via
  Route Handlers — **não query o DB direto** (regra mestra).

### D6 — Sem nova RPC/enum; schema prep puro

- Migration 0029 = schema prep (tabela nova + coluna em `notifications` + relax de CHECK).
  **Sem funções/RPCs/enums novos**. Writes em `notifications`/`whatsapp_conversations`
  via service_role (DML full já concedido 0015). Padrão de split respeitado
  (0025/0027 — schema prep separado de RPCs).

### D7 — PII e secrets (endurecimento ADR-018 D8/D10)

- **OTP plaintext nunca sai do backend**: `type:'otp'` gera + envia internamente; response
  e `notifications.payload` sem `otp_code`. O endpoint `POST /api/internal/deliveries/{id}/otp`
  tem `redact:["otp_code"]` aplicado **antes** de `recordResult` (não só na response) —
  assim o `integration_events.result` cacheado também não contém o plaintext, e o replay
  devolve o resultado já-redacted. Provado live: ledger `result:{ok:true,reason:"generated"}`
  sem `otp_code`, replay 200 sem `otp_code`, `otp_generated` não duplica.
- **Sem PII do cliente pré-atribuição**: mensagem `offer` só valor/veículo/prioridade +
  signed link. PII (endereços/contatos) só em `assignment` (pós-atribuição).
- **Segredos** (`DATACRAZY_API_KEY`, `EVOLUTION_API_KEY`, `service_role`) nunca logados;
  erros de provider sanitizados (só status HTTP).

## Consequências

- `notifications` passa a ser escrito (gap Sessão 03 fechado). `whatsapp_conversations`
  habilita o roteamento híbrido. n8n (Phase 2) consome **2 endpoints novos**
  (`notifications/send`, `reconciler/scan`) além dos 10 system + 4 driver + 1 webhook da
  Sessão 14-15.
- Provider abstraction swapável: a decisão "two-number" (DataCrazy + Evolution = 2 números
  WhatsApp) pode ser consolidada em Evolution-only p/ todo outbound sem reescrever
  (resolver P2 do plano) — basta não registrar o DataCrazy.
- **Ressalvas (regra mestra — não simulado PASS)**: envio WhatsApp live + nomes dos
  campos do payload inbound DataCrazy dependem de provisionamento real (Evolution API V2,
  credenciais DataCrazy) — Phase 2 (n8n) valida live. Geo `/quote`+`/enrich` ainda 501
  (Sessão 20). Storage RLS comportamental, UI, rate limiting/mTLS → Sessões 17-19/22/26.

## Referências

- Plano: `docs/plans/sessao-16-whatsapp-n8n.md` (Phase 1).
- Padrão provider + 501: `lib/services/geo.ts:8-11`, `lib/providers/routing-provider.ts`,
  ADR-005, ADR-019 D5.
- Handler pipeline: `lib/api/internal-handler.ts:24`; idempotency: `lib/idempotency/ledger.ts`.
- Signed link: `lib/auth/signed-link.ts:67-89`; ADR-020 D3.
- `notifications` schema: `supabase/migrations/0011_integrations_notifications_pod.sql:40-59`.
- Webhook router: `lib/api/webhook-handler.ts`, ADR-020 D5.
- Regra mestra: `CLAUDE.md`, `ARCHITECTURE.md:71-72`, ADR-018 D1, ADR-020:168.