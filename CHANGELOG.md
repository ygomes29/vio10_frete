# CHANGELOG.md — Histórico do ViO10

Formato: sessão + data + escopo.

## [Sessão 16] — 2026-08-31 — WhatsApp outbound híbrido + n8n trigger model/contrato/live (ADR-021, ADR-022) — Phase 1 + design + Phase 2 trigger model

> **Phase 1 (backend outbound) + design/contrato n8n + Phase 2 (trigger model live)
> concluídos.** Phase 3: sub-workflows restantes + reconciler scan + n8n→backend
> reachability (tunnel/deploy público) + envio WhatsApp real. Decisões do usuário: D1
> híbrido (DataCrazy nativo + Evolution V2 fallback), D2 backend envia+loga, D3 backend é o
> único inbound.

### Validado live (Phase 2 — não simulado)
- **pg_net egress** dev Supabase → n8n público (`https://n8n.processlabcorp.com.br/`):
  echo workflow + exec 209392 (body `{"hello":"from-pgnet"}`, `user-agent: pg_net/0.20.4`).
- **Dispatcher `VIO10-dispatcher`** (id `8M68aj7oExxijS73`): Webhook → Code valida
  `x-webhook-secret` (reject `invalid_webhook_secret`, exec 209410) + mapeia
  `event_type`→workflow. Ping manual → exec 209409 `success` route `delivery_created→#2-enrich`.
- **DB trigger `trg_delivery_events_notify_n8n`** (AFTER INSERT `delivery_events`, função
  `notify_n8n_delivery_event` SECURITY DEFINER `net.http_post` ao dispatcher c/
  `x-webhook-secret`) — **infra de runtime, NÃO migration** (ADR-022 D1). Provado: INSERT
  real → n8n exec c/ `event_id` exato — `delivery_created`→#2 (209417), `delivered`→#12
  (209419), `otp_generated`→NOOP-chain (209420), `round_closed`→#8 (209421).
- **Sub-workflow `VIO10-#2-enrich`** (id `zQsbwxwW9I8wD32L`): HTTP Request →
  `http://localhost:3000/.../{id}/enrich` c/ `x-internal-api-key` + `Idempotency-Key:{corr}-enrich`
  — exec 209427 montou o request (wiring provado) + `ECONNREFUSED` = gap honesto de
  reachability (n8n público → backend localhost; handlers já provados via curl Sessão 14-15).
  `service_role` nunca no n8n (3 fronteiras auth); OTP plaintext nunca transita n8n.

### Adicionado
- **Migration 0029** (schema prep): `notifications.recipient_phone` + relax CHECK
  `notifications_at_least_one_recipient_chk` (aceita `recipient_phone` p/ recebedor
  externo) + tabela `whatsapp_conversations` (phone UNIQUE, conversation_id, provider,
  window_expires_at, last_inbound_at; RLS default-deny; service_role all). **Sem
  funções/RPCs/enums novos** (split respeitado).
- **Provider abstraction WhatsApp** (copy do padrão geo ADR-005): interface
  `WhatsAppProvider` + registry + `WhatsAppProviderNotConfiguredError` (501
  `whatsapp_provider_not_configured` sem provider). `datacrazy-provider` (Bearer, exige
  `conversationId`), `evolution-provider` (apikey, body nested+fallback flat #2570),
  `hybrid-whatsapp-provider` (roteamento D1), `whatsapp-registration` (idempotente).
- **`POST /api/internal/notifications/send`** (system, ADR-019 D1 pipeline +
  `withIdempotency`): `{type:'offer'|'otp'|'assignment'|'status_update'|'terminal',
  offer_id?, delivery_id?}`. `sendNotification` resolve destinatário, gera signed link
  (offer), escolhe provider híbrido, envia, upsert em `notifications` (idempotente
  `notif:{type}:{id}`); OTP gera+envia internamente (plaintext nunca sai). Erros
  sanitizados (só status HTTP).
- **`POST /api/internal/reconciler/scan`** (system, read-only, state-based):
  `scanReconciler` devolve estado preso (rodadas `open` expiradas, drafts sem quote,
  `searching_driver` sem rodada). Sem `Idempotency-Key` (ledger `skip`).
- **`lib/api/webhook-conversation-capture.ts`**: upsert `whatsapp_conversations` no
  inbound (best-effort, antes do roteamento).
- **ADR-021** (D1-D7) + **ADR-022** (D1-D9, supersede ADR-018 D2: Realtime→Database
  Webhooks). `N8N_WORKFLOWS.md` revisado (trigger model, tabela de endpoints, #6/#7/#8/
  #10/#11/#12/#13/#15/#1/#16, caminho feliz).

### Corrigido (bugs reais, achados+fixados+provados live)
- **`withIdempotency` release-on-throw** (`lib/idempotency/ledger.ts`): `fn()` que lança
  (provider 501/5xx) deixava a claim `pending` → retry com mesmo `Idempotency-Key` caía em
  `in_flight` 409, envenenando a chave e bloqueando a retomada do n8n. Agora
  `releaseClaim` deleta a claim e propaga a exceção. Distinção: lança=transitório/retryable,
  retorna RpcResult=terminal/replayable. Provado live. +2 testes.
- **`payload NOT NULL`** (`lib/idempotency/ledger.ts`): `integration_events.payload` é NOT
  NULL (default `'{}'`) mas endpoints `sensitive` (OTP) passavam `null` → insert falhava
  **silenciosamente** (erro em `.error`, supabase-js não lança) → `claimIdempotency` caía
  no fallback `skip` → **endpoints sensitive sem idempotência**. Sintoma: OTP nunca gravava
  row no ledger. Fix `insertRow.payload = opts.payload ?? {}`. Provado live. +2 testes.
- **OTP redact-before-record** (`lib/api/internal-handler.ts`): `recordResult` persistiria
  `otp_code` plaintext em `integration_events.result` (jsonb) indefinidamente (além do TTL
  do OTP) — ADR-021 D7. Agora redact aplica-se **antes** de `withIdempotency` gravar →
  ledger, replay e response todos sem `otp_code`. Provado live: ledger `result` sem
  `otp_code`; replay (mesma key) não re-executa (`otp_generated` +1 não +2).

### Validação
- `tsc --noEmit` limpo (fonte; `.next/dev/types` gerado ignorado). **175/175 vitest**
  (16 suítes, +4 regressões ledger). Live (dev, real): OTP c/ `Idempotency-Key` → 200 sem
  `otp_code` + ledger `processed` + `delivery_otps` hash + `otp_generated`; replay não
  duplica. Regressão DB não executada (mudanças só em TS, sem migration).

### Ressalva (regra mestra — não simulado PASS)
- Phase 2 n8n live (importar/configurar/validar workflows) — blocked em n8n URL + Public
  API key + versão (usuário). Envio WhatsApp real requer credenciais Evolution/DataCrazy.
  DB Webhook (`pg_net` + `supabase_functions` sobre `delivery_events`) requer provisionamento.
  Geo `/quote`+`/enrich` 501 (Sessão 20). Storage RLS comportamental, UI, rate
  limiting/mTLS → Sessões 17-19/22/26.

### Phase 3 — sub-workflows provados live (não simulado)
- **Reachability destravada**: deploy Vercel público `https://vio10-frete.vercel.app`
  (Next.js, env vars server-side setadas) — n8n público → backend público, sem ECONNREFUSED.
- **8 fluxos backend provados end-to-end c/ chave real** (`INTERNAL_API_KEY` colada pelo
  usuário em cada workflow):
  - `#2-enrich` (`zQsbwxwW9I8wD32L`) → `POST /deliveries/{id}/enrich` → 501 geo_provider.
  - `#6-offer` (`Dnhh0QfgNllDUxbY`) → `POST /notifications/send` {offer} → 501 whatsapp.
  - `#10-assign` (`LkEvTnM5CbJV9y7L`) → `POST /notifications/send` {assignment} → 501.
  - `#11-update` (`H7FdzdAtyzmaqHSk`) → Webhook → Code "Build items" (emite status_update
    sempre + otp se `in_transit`) → `POST /notifications/send` → 501; **branch in_transit→otp
    provado** (2 items emitidos vs 1 p/ outros; backend `type:'otp'` → generate_delivery_otp
    interno, otp_code não vaza ADR-022 D5).
  - `#12-notify` (`2oqc2gwbcJMowcs4`) → `POST /notifications/send` {terminal} → 501.
  - `#13-confirm` (`kVOnPyLnoCqcZ6QZ`) → `POST /deliveries/{id}/confirm` → 422 pod_required.
  - `#14-failure` (`Mf9WMsRrmYW2nARd`) → `POST /deliveries/{id}/transitions` → not_found.
  - `#15-reconciler` (`pH9LnGYVKYIEMY0z`, Schedule `*/5 * * * *`) → `POST /reconciler/scan` → 200.
- **Dispatcher** (`8M68aj7oExxijS73`): mapeia 7 webhook URLs; `in_transit` unificado → #11;
  `round_closed`/`otp_generated`/etc → NOOP (fix do loop latente #8 preservado).
- **3 bugs reais do n8n httpRequest v4.2 achados+corrigidos+provados live**: (a) objeto
  literal aninhado em `JSON.stringify` → `invalid syntax` → fix `JSON.parse('...')` como
  valor (objeto single-level); (b) delimitador `{{ }}` colide c/ `}}` em JSON string →
  `invalid syntax` → mesmo fix; (c) **campo `url` c/ `{{ }}` inline NÃO resolve** → passa
  literal como path param `[id]` → backend 500 (mascarado por 401 antes da chave real) →
  fix URL em modo expressão `={{ '...'+$json.body.delivery_request_id+'/...' }}`.
- **Regressão**: vitest 175/175 (16 suítes) — sem regressão (nenhum código do repo mudou).
- **Ressalva**: #8-close + #9-nova-rodada (bloqueado por geo 501 — Sessão 20) + WhatsApp
  real (credenciais) + regressão DB 10/10 suítes. Pings de teste mutaram dev DB (delivery
  `33333333-...` → failed; ledger entries via release-on-throw vazios) — harmless, re-reset
  antes de produção.

### Phase 3b — WhatsApp real proven live (Evolution cold, não simulado)
- **Provider Evolution V2 configurado no Vercel** (env vars server-side `EVOLUTION_API_URL`,
  `EVOLUTION_API_KEY`, `EVOLUTION_INSTANCE_NAME=Olivia - NEA` — instância pública/https,
  número conectado `553185088086`). Híbrido ADR-021 D1: cold → Evolution; conversa aberta →
  DataCrazy.
- **Estágio 1 — provider registrado (saída do 501)**: ping `notifications/send {type:offer,
  offer_id:<fake>}` → antes `501 whatsapp_provider_not_configured`, depois `422 not_found`
  (passou o check do provider em `sendNotification` linhas 200-202 → prova 501 sumiu sem enviar).
- **Estágio 2a — backend → Evolution → WhatsApp (direto)**: `notifications/send {type:terminal,
  delivery_id:33333333}` c/ `pickup_contact_phone=5531997722783` (UPDATE fixture dev) →
  `200 {ok:true, notification_provider:evolution}`; log `notification.terminal ok:true
  provider:evolution`; DB `notifications status:sent provider:evolution
  recipient_phone=5531997722783 external_id=3EB0C773C216F8CE544601` (ID real Baileys/WhatsApp).
  Insight: `type:terminal`/`status_update` resolvem destinatário do próprio `delivery_requests`
  (`pickup_contact_phone`) **sem guard de estado e sem driver/assignment** — scaffolding mínimo
  p/ validar provider.
- **Estágio 2b — cadeia n8n completa → Evolution → WhatsApp**: `INSERT delivery_events(
  event_type:driver_to_pickup, delivery_request_id:33333333)` → trigger
  `trg_delivery_events_notify_n8n` → pg_net → dispatcher → `#11-update` (Code Build items:
  1 item status_update) → `notifications/send {type:status_update}` → backend → Evolution →
  WhatsApp. Nova row DB `event_type=status_update status=sent
  external_id=3EB0B5E3A4111F0A7A56BC` (ID NOVO, distinto do 2a) em **~5s** de latência
  end-to-end; log `notification.status_update ok:true provider:evolution`. Essa row só pode
  existir se o n8n chamou o backend → prova cadeia n8n→Evolution p/ envio real.
- **Ambos confirmados pelo usuário** (mensagens chegaram no celular `+5531997722783`):
  `ViO10 — Corrida 33333333 falhou.` (2a) e `ViO10 — Atualização da corrida 33333333: falhou.`
  (2b). Regra mestra íntegra: não simular PASS.
- **Fix provider**: `evolution-provider.ts:28` agora `encodeURIComponent(config.instanceName)`
  — nomes c/ espaço/hífen quebravam o path `/message/sendText/{instance}` (404). Bug inicial
  era nome errado ("jady gomes" não existia); corrigido p/ slug real "Olivia - NEA" + encoding
  defensivo. 404 ≠ 400/422 → não tenta próximo shape; falha direto.
- **Regressão**: vitest 175/175 (16 suítes) — sem regressão após o fix.
- **Ressalva**: DataCrazy in-conversation (janela 24h, só c/ conversa real iniciada pelo
  usuário — não sintetizável) + OTP real ao recebedor (`type:otp`, precisa delivery em
  `in_transit` — bloqueado por geo 501 no fluxo normal, só via fixture SQL direta) não validados
  live. Evolution cobre todo cold (crítico). `service_role` nunca no n8n (3 fronteiras auth);
  OTP plaintext nunca transita n8n (ADR-022 D5).

## [Sessão 15] — 2026-08-29 — Endpoints driver/user-facing, signed links, webhook router, cookie/middleware full (ADR-020)

> Camada de aplicação **pura** — sem migration/RPC/enum/grant novo. Os 4 RPCs driver-facing
> (`respond_to_offer`, `submit_proof_of_delivery`, `transition_delivery`,
> `set_driver_availability`) são finais desde Sessões 09-12. Fecha a contract surface do
> ADR-018 D5 e a ressalva de Sessão 14/ADR-019 D7.

### Adicionado
- **Signed links** (`lib/auth/signed-link.ts`): HMAC-SHA256 create/verify, token
  `base64url(payload)."."base64url(hmac)`, payload `{o,d,e,n}`, TTL 900s, IDOR-protegido
  (`o===expectedOfferId`), timing-safe, **fail-closed** se `ACTION_LINK_SIGNING_SECRET`
  ausente. + testes (create/verify/IDOR/expirado/tampered/malformed/fail-closed).
- **Handlers** (`lib/api/`): `user-handler.ts` (`handleUserPost` — cookie JWT, getUser→401,
  sem ledger), `offer-respond-handler.ts` (`handleOfferRespondPost` — dual-auth cookie-ou-
  token, IDOR), `webhook-auth.ts` (`verifyDatacrazySignature` timing-safe fail-closed),
  `webhook-handler.ts` (`handleWebhookPost` — signature→dedup `webhook_events`→parse→route→
  200 sempre). + testes (95 novos).
- **Service layer driver** (`lib/services/driver.ts`): `respondToOffer`/`submitProofOfDelivery`/
  `transitionDeliveryDriver`/`setDriverAvailability` (client-agnostic; `set_driver_availability`
  void+raise mapeado p/ 403; `resolveDriverId` de `auth.uid()`). Validators
  (`validateRespondOfferBody`/`validatePodBody`/`validateTransitionBody`/
  `validateAvailabilityBody`). + testes.
- **Route Handlers (6)**: `POST /api/offers/{id}/respond` (dual-auth),
  `POST /api/driver/deliveries/{id}/transitions` (cookie), `POST /api/driver/deliveries/{id}/pod`
  (cookie, sensitive), `POST /api/driver/availability` (cookie, resolveDriverId),
  `POST /api/internal/offers/{id}/respond-link` (internal-auth, generator sem ledger),
  `POST /api/webhooks/datacrazy` (signature router). + `app/auth/login/page.tsx` (placeholder).
- **Middleware full** (`lib/supabase/middleware-client.ts` sem `server-only`; `middleware.ts`
  reescrito: `getUser()` refresh via `setAll`→response.cookies, protege `/driver`/`/admin`/
  `/business` → 307 `/auth/login?redirect=` (`NextResponse.redirect` default, validado live), libera `/api/*`/`/auth/*`/estáticos).
- **`lib/rpc/result.ts`**: `reasonToStatus` estendido (unauthenticated→401, offer_expired→410,
  offer_already_responded/delivery_not_searching/pod_already_submitted/invalid_transition/
  reassignment_limit_reached→409, offer_not_found_for_driver→404, invalid_bid_amount/
  invalid_response_type/invalid_pod→400). + testes.
- **ADR-020** (D1-D10) + BACKEND §11 + ARCHITECTURE §15 + `.env.example`
  (`ACTION_LINK_SIGNING_SECRET`, `DATACRAZY_WEBHOOK_SECRET`, `NEXT_PUBLIC_APP_URL`).

### Validação
- `tsc --noEmit` clean; **124/124** vitest PASS (12 suítes — 81 novos + 43 Sessão 14).
- Regressão DB: reset+replay 0001→0028 (28/28), 10/10 suítes PASS (zero regressão).
- Live vertical slice `next dev`+curl (ver plano): auth driver cookie, endpoints driver
  200, 401 sem cookie, signed link generator+respond+expirado/tampered+replay, webhook
  signature/dedup/inválida, middleware redirect.
- **Ressalvas (declarado, não PASS)**: UI PWA/dashboards/portal (Sessões 17-19),
  DataCrazy/WhatsApp outbound real (Sessão 16), provider Google Maps (Sessão 20 — `/quote`
  `/enrich` 501), Storage RLS comportamental (Sessões 17-19).

## [Sessão 14] — 2026-08-29 — Camada de API: Next.js Route Handlers (pivot n8n → API layer)

> Sessão 14 como escrita no roadmap (implementar n8n) estava BLOCKED (sem instância n8n,
> Route Handlers, WhatsApp). Usuário pivotou para a **camada de API** — a camada que n8n
> **e** os apps consomem, indicada pela regra de execução ("backend → regras → APIs") agora
> que backend+regras (Sessões 03-12) está validado.

### Adicionado
- **Fundação Next.js 16.3.3**: `package.json` (next@16.3.3, react@19.2.8, @supabase/ssr,
  @supabase/supabase-js, vitest@4.1.11), `tsconfig.json`, `next.config.ts`, `vitest.config.ts`,
  `app/layout.tsx`+`app/page.tsx` (placeholder), `middleware.ts` (mínimo), `.env.example`
  (placeholders), `tailwind.config.*`/`postcss.config.*`.
- **Clients Supabase**: `lib/supabase/server-client.ts` (user-scoped, `@supabase/ssr`,
  cookie→JWT→`auth.uid()`, RLS) + `lib/supabase/system-client.ts` (`service_role`,
  `server-only`, RLS bypass, singleton) + `lib/supabase/internal-auth.ts`
  (`verifyInternalApiKey` timing-safe, fail-closed).
- **Idempotency ledger**: `lib/idempotency/ledger.ts` — `withIdempotency` (claim/replay/
  in_flight/skip) em `integration_events` (service-only). `idempotency_key` precede
  `external_event_id`; `onConflict` dinâmico por coluna.
- **Provider abstraction**: `lib/providers/{geocoding,routing}-provider.ts` (ADR-005),
  registry vazio — `/quote`+`/enrich` = 501 até Sessão 20.
- **Service layer + helpers**: `lib/services/{deliveries,dispatch,geo}.ts`,
  `lib/api/{http,internal-handler}.ts`, `lib/rpc/{call,result}.ts`.
- **Route Handlers system/internal** (`app/api/internal/**/route.ts`, 9 endpoints):
  `deliveries` (create), `deliveries/[id]/{quote,enrich,confirm-quote,dispatch/rounds,
  confirm,otp,transitions}`, `dispatch/rounds/[id]/close`. Fluxo padrão em
  `handleInternalPost`: internal-auth → parse → validate (pré-claim) → idempotency →
  RPC → map → HTTP.
- **ADR-019** — Camada de API: Route Handlers (D1-D9: handler fino; dois scopes; shared
  secret; idempotency ledger; provider 501; mapeamento RPC→HTTP; auth user mínima; logs
  sem secrets; validação real não simulada).
- **Testes unitários** (vitest, 43/43 PASS): `validateCreateDelivery`,
  `validateDispatchRoundBody`, `verifyInternalApiKey` (fail-closed), `reasonToStatus`/
  `toApiResponse`/`isReplay`, `getCorrelationId`/`getIdempotencyHeaders`, `withIdempotency`
  (run/replay/in_flight/race/skip com client mockado). Stub `server-only` no vitest.
- **BACKEND.md §10** (Camada de API / Route Handlers) + **ARCHITECTURE.md §14**.

### Validado (real, dev — não simulado)
- **Regressão 10/10 suítes PASS** (pós reset+replay 0001→0028, 28/28 limpo): invariants,
  rpcs, authz 21/21, auth_lifecycle 34/34, creation 37/37, pricing 62/62, dispatch 65/65,
  bid 61/61, lifecycle 67/67, pod_completo 40/40 — 418 asserções, zero regressão.
- **Vertical slice via `next dev`+curl** (19/19 comportamentos): 401 sem secret (fail-closed);
  create 200 (system path); **idempotência replay** (mesmo `Idempotency-Key` → mesmo id,
  0 duplicação, `integration_events` gravado); invalid 400; `/quote`+`/enrich` 501;
  transitions draft→cancelled 200 + `invalid_transition` 422; `wrong_state` 409;
  confirm-quote 200; open round 200; SWAC `no_candidates` 200 (ok=true) + **SWAC `won→assigned`
  200**; **OTP 200 (6 dígitos ao caller system, ausente do log — sensitive D8)**; confirm
  id inexistente 422; **confirm `in_transit`+POD → `delivered` 200** (evento `delivered`
  actor system). Estado verificado no DB via Management API.
- **Bugs corrigidos**: `ledger.ts` `dedupKey` referenciava `opts.idempotency_key` (snake_case
  inexistente) → `opts.idempotencyKey` (value ficava undefined, ledger quebrado); `onConflict`
  fixo → dinâmico por coluna. `server-client.ts` import `createServerClient` conflitava com
  a fn local → alias `createSSRClient`. `result.ts` `ok` duplicado no spread → reordenado.

### Ressalva
- Endpoints driver/user-facing (`respond_to_offer`, `submit_proof_of_delivery`, transitions
  driver-side via JWT+signed links), webhook router DataCrazy, cookie/middleware full →
  **Sessão 15** (declarado, não PASS).
- Provider Google Maps real (`/quote`,`/enrich` end-to-end) → **Sessão 20** (501 hoje).
- Implementação n8n (instância provisionada) → reabre quando Route Handlers + WhatsApp existirem.

## [Sessão 13] — 2026-08-28 — Arquitetura dos workflows n8n (design dos 16 workflows)

### Adicionado
- **ADR-018** — Arquitetura dos workflows n8n: D1-D11 (n8n orquestrador nunca fonte da
  verdade; trigger Realtime+reconciler/webhook; timeout n8n Wait+backstop DB; raio
  progressivo orquestrado pelo n8n com config em constantes no MVP; Route Handler contract
  surface enumerada — 12 endpoints; idempotência R17 mapeada; retry/DLQ+reconciler;
  geocoding/routing via backend; n8n nunca decide atribuição — SWAC decide; correlation_id
  end-to-end + PII minimizada; escopo = design, Sessão 14 = implementação).
- **`docs/N8N_WORKFLOWS.md`** — design completo dos **16 workflows** no template "para cada
  workflow" (trigger, input, validações, operações, chamadas ao backend, eventos gerados,
  retries, idempotency key, tratamento de erro, logs). Workflow #13 (Sessão 12) formalizado
  no template e integrado ao reconciler. Modelo de trigger, timeout, contract surface,
  idempotência R17 e caminho feliz documentados.
- **`docs/DECISIONS.md`** — ADR-018 indexado + decisões Sessão 13 (D1-D11).
- **`docs/CODE_REVIEW.md`** — Sessão 13 PASS (design review).

### Decisões
- **Trigger model**: Realtime sobre `delivery_events` (estado interno) + reconciler
  periódico (reprocessa eventos perdidos/estados presos) + webhook (inbound). Confirmadas
  com o usuário via `AskUserQuestion`.
- **Timeout da rodada**: n8n Wait node primário + reconciler backstop DB (fecha rodadas
  `expires_at < now()` e `open`). **Sem schema novo** — `expires_at` já existe em 0023.
- **n8n nunca decide atribuição**: `select_winner_and_claim` (system-only) decide +
  chama `claim_delivery` atomicamente; ACEITAR ≠ GANHAR (ADR-006). n8n não chama
  `claim_delivery` direto (GATE Sessão 10).
- **Route Handler contract surface**: 12 endpoints; os 5 system-only vão por Route Handlers
  system-scoped (Service Role interno), nunca expostos ao n8n/IA. Contrato de implementação
  para Sessão 14 (n8n) e Sessões 17-19 (Next.js Route Handlers).
- **Escopo = design puro**: sem migration/schema/RPC/grant novo; sem validação live (n8n
  não provisionado; não simular PASS — regra mestra). Implementação Sessão 14.

### Validado
- **Nenhum** (design puro — n8n/WhatsApp não provisionados). Contrato verificado contra as
  migrations: 23 valores de `delivery_event_type` (21 em 0002 + `pod_submitted` 0025 +
  `otp_generated` 0027), 11 RPCs centrais (5 system-only), assinaturas e enums conferidos.
  Nenhuma RPC/evento inventado.

### Não implementado (deferido)
- Implementação dos workflows em instância n8n provisionada (credenciais, nodes) → Sessão 14.
- Live WhatsApp/DataCrazy (OTP/ofertas entregues de verdade) → Sessões 15-16.
- App Next.js (Route Handlers implementados, Storage API) → Sessões 17-19.
- `dispatch_config` table (config de raio/max_rounds em DB) → Sessão 26 (MVP: constantes n8n).
- Provider geográfico real (Google Maps) → Sessão 20 (MVP: contrato via Route Handler).
- Kill switches/limites em DB → Sessão 26.

### Riscos
- "Camada externa não live-validada" (Sessão 12) **mantido aberto** — Sessão 13 é design;
  validação live da orquestração+n8n+WhatsApp é Sessão 14/15-16.
- Dívida técnica observada: config de dispatch em constantes do n8n (não DB) —
  endurecido em Sessão 26.

### Veredito
- **GO para Sessão 14** (implementação dos workflows em instância n8n provisionada).

## [Sessão 12] — 2026-08-28 — POD completo (OTP do recebedor, gate de geo, gate de pickup POD, Storage)

### Adicionado
- **ADR-017** — POD completo: OTP do recebedor, gate de geolocalização, gate de pickup POD,
  Storage `pod-photos`. D1 ciclo de vida do OTP em tabela dedicada `delivery_otps` (hash
  salt+sha256, TTL, lockout, geração system-only, validação no submit com `for update`,
  match consume na mesma tx do insert); D2 gate de geo (configurável via
  `metadata.geo_tolerance_m`, default 200m, `st_distance`, skip se POD sem location);
  D3 gate de pickup POD em `at_pickup→picked_up`; D4 verificação do recebedor = OTP match
  (foto = evidência, either-or preservado); D5 bucket `pod-photos` privado + RLS INSERT p/
  driver com assignment ativa; D6 camada externa especificada (n8n/WhatsApp), validação
  live deferida; D7 sem coluna `verified` (gates enforce na transição); D8 split 0027/0028
  (gotcha `ALTER TYPE ADD VALUE` in-tx); D9 ator via `auth.uid()`.
- **Migration 0027** (`0027_pod_completo_prep.sql`) — schema prep: enum `otp_generated`,
  tabela `delivery_otps` (unique `delivery_request_id`, delivery-only; hash/salt/expires/
  attempts/max_attempts/consumed_at), index, RLS + SELECT policy `delivery_otps_sel`,
  grants (service_role all, authenticated select under RLS, anon nada), helper
  `is_assigned_driver_of(uuid)` SECURITY DEFINER stable, bucket `pod-photos` (privado,
  50MiB, png/jpeg) com `on conflict do nothing`, RLS policy `pod_photos_insert` em
  `storage.objects` p/ authenticated. **Sem função que referencie o enum novo** (D8).
- **Migration 0028** (`0028_pod_completo_rpcs.sql`) — 4 RPCs `SECURITY DEFINER`:
  - `generate_delivery_otp(uuid, int default 900, int default 5, uuid default
    gen_random_uuid())` → `table(ok, reason, otp_code)` — **system-only** (5º), gera código
    6 dígitos crypto (`gen_random_bytes`), hash salt+sha256 (`pgcrypto`), upsert em
    `delivery_otps`, emite `otp_generated`, retorna plaintext só ao caller system.
  - `submit_proof_of_delivery(...)` — assinatura **inalterada**, adiciona validação de OTP
    contra `delivery_otps` (`for update`, `otp_not_generated`/`otp_expired`/
    `otp_max_attempts`/`otp_already_used`/`otp_invalid`, match → `consumed_at=now()` na
    mesma tx) quando `pod_type='delivery' and p_otp_code is not null`; foto-only pula.
  - `confirm_delivery(uuid, int default null, uuid default gen_random_uuid())` →
    `table(ok, reason, pod_id)` — assinatura **mudou** (drop da 2-param antes do create);
    system-only inalterado; novo `p_geo_tolerance_m` repassado em `metadata.geo_tolerance_m`.
  - `transition_delivery(...)` — assinatura **inalterada**, `search_path` agora
    `public, extensions, pg_catalog` (PostGIS); adiciona gate de pickup POD
    (`pickup_pod_required`) e gate de geo (`pod_geolocation_out_of_range`, default 200m,
    skip se sem location).
- **Testes** — `supabase/tests/test_vio10_pod_completo.sql` (novo, 40 asserções): OTP
  geração/validação/lockout/expirado/regeneração, replay (otp_already_used +
  pod_already_submitted), geo gate (dentro/fora/sem-location/default), pickup gate,
  confirm_delivery geo param, Storage estrutural. Regressão: `test_vio10_lifecycle.sql`
  (T1 + T3/T10-T20 inserem pickup POD antes de `picked_up`; 65→67), `test_vio10_rpcs.sql`
  (TR6 pickup POD; 48 mantido).
- **Docs** — `DELIVERY_LIFECYCLE.md` (POD two-phase profundidade Sessão 12), `DECISIONS.md`
  (ADR-017 + decisões), `BACKEND.md` §4.7, `SECURITY.md` (OTP lifecycle, geo gate, pickup
  gate, Storage, 5º system-only), `N8N_WORKFLOWS.md` (workflow #13 entrega concluída),
  `DATACRAZY_INTEGRATION.md` (receiver-OTP), `GEOLOCATION.md` (geo gate do POD).

### Decisões
- **Escopo "DB completo + especificar externa"** (decisão do usuário): o repo não tem
  camada de aplicação (sem Next.js, sem n8n, sem WhatsApp). Live-validar a entrega real via
  WhatsApp e o workflow n8n é impossível neste ambiente; a regra mestra proíbe simular PASS.
  Decisão: construir a camada DB/RPC completa + especificar (docs + RPCs que a camada
  externa consome) a camada n8n/WhatsApp, marcando validação live como **deferida**.
- **Gate de geolocalização: tolerância configurável, gate duro** (decisão do usuário):
  `metadata.geo_tolerance_m` (default 200m); gate duro quando há location; skip quando não
  há (GPS de PWA impreciso). Endurecer para exigir location fica para sessão posterior.
- **Sem coluna `verified` no POD** (D7): os gates (OTP + geo + pickup) enforce na
  transição; `delivered` só se todos passarem. Coluna redundante — schema mínimo.
- **5º RPC system-only** (`generate_delivery_otp`): o código de verificação do recebedor é
  da plataforma, não do driver — um driver gerando o OTP veria o código e forjaria a
  "verificação". `authenticated` nem EXECUTE recebe.

### Validado (real, no dev `rtoyfiqngyicqtuzwfhz` — nunca produção)
- Reset via SQL + replay 0001→0028 = **28/28 limpo** (sem MIGFAIL). `'otp_generated'`
  referenciável em 0028; bucket `pod-photos` criado; policy `pod_photos_insert` aplicada.
- Inventário: **27 tabelas** (`delivery_otps` nova), RLS 27/27, `anon`=0 em public.
  `generate_delivery_otp` system-only (5º; execute só `service_role`).
  `confirm_delivery` 3-param (2-param dropped). `submit_proof_of_delivery`/`transition_delivery`
  refinadas (grants inalterados). Bucket `pod-photos` (privado) + policy `pod_photos_insert`.
- **10 suítes PASS** (não simulado): invariants 13, rpcs 48, authz 21, auth_lifecycle 34,
  creation 37, pricing 62, dispatch 65, bid 61, lifecycle 67, pod_completo 40.
- **Storage RLS comportamental + camada n8n/WhatsApp NÃO validados live** — declarado
  explicitamente (não simulado). Storage: só validação estrutural (bucket + policy via
  `storage.buckets`/`pg_policies`); comportamental fica para Sessões 17-19 (app Next.js +
  Storage API). n8n workflow #13 + envio OTP via WhatsApp: especificados em docs; live
  deferido para Sessões 14 (n8n) + 15-16 (WhatsApp/DataCrazy).
- Veredito **GO → Sessão 13** (n8n: arquitetura dos workflows).

### Corrigido (durante a validação real)
- **Bug de teste `pod_completo` C1 (lógica, não RPC):** C1 esperava
  `pod_already_submitted` no 2º submit delivery com OTP, mas o 2º submit reusa o OTP já
  consumido → o bloco de validação OTP roda **antes** do insert do POD → retorna
  `otp_already_used` primeiro (comportamento correto do RPC). Reescrito C1 em 3 passos:
  C1a_first=submitted, C1b_otp_already_used (OTP consumido primeiro), C1c_pod_already_submitted
  (3º submit foto-only bypassa OTP gate → bate unique). 38→40 asserções, todas PASS. Nenhum
  bug de RPC em runtime (lições Sessão 07/08 — ambiguidade `as t` + PostGIS em `extensions`
  — aplicadas proativamente).
- **Regressão de gates:** pickup gate (D3) quebra `lifecycle` T1/T3/T10-T20 + `rpcs` TR6
  (agora `at_pickup→picked_up` exige pickup POD). Corrigido inserindo pickup POD antes das
  transições `picked_up`. Geo gate (D2) não quebra testes existentes (submetem POD sem
  location → skip).

### Não implementado (fora do escopo, deferido)
- **Live n8n** (workflow #13 implementado, instância provisionada) → Sessão 14.
- **Live WhatsApp/DataCrazy** (OTP entregue de verdade ao recebedor) → Sessões 15-16.
- **App Next.js** (Route Handlers, frontend, Storage API exercitável) → Sessões 17-19.
- **Exigir location no delivery POD** (endurecer geo gate de skip→hard-required) → sessão
  posterior (MVP skip quando sem GPS).
- **Storage RLS comportamental** → Sessões 17-19 (requer app Next.js + Storage API).
- **Hardening do lock-ordering** `claim_delivery`↔SWAC (dívida ADR-015 D4) → independente.

## [Sessão 11] — 2026-08-28 — Ciclo completo (máquina de estados pós-`assigned` + POD gate)

### Adicionado
- **ADR-016** — ciclo completo pós-`assigned` + POD gate. D1 matriz de authz por
  (ator × transição) dentro de `transition_delivery` (system/admin/driver/business —
  M estrutural primeiro, depois R de papel); D2 limite de reatribuição via
  `p_metadata->>'max_reassignments'` (sem teto = ilimitado, back-compat); D3
  `cancelled_reason`/`failed_reason` capturados do metadata (colunas existiam mas nunca
  eram escritas); D4 POD two-phase `submit_proof_of_delivery` (driver-scoped) +
  `confirm_delivery` (system-only) — "Submeter POD ≠ entregue" (análogo a ACEITAR ≠
  GANHAR); D5 POD gate em `in_transit→delivered` dentro de `transition_delivery`
  (defense in depth — `confirm_delivery` pré-valida e o gate re-valida); D6 completude
  do POD no MVP (delivery: storage/otp + receiver_name; pickup: storage/otp/notes) +
  unique `(delivery_request_id, pod_type)` → `pod_already_submitted`; D7 ator via
  `auth.uid()` + evento `pod_submitted`; D8 sem tabela nova (enum + constraint + 2 RPCs
  + 1 RPC refinada); D9 split em 2 migrations (gotcha `ALTER TYPE ... ADD VALUE`
  in-tx — 0025 enum+constraint, 0026 RPCs que referenciam `'pod_submitted'`).
- **Migration 0025** — schema prep: `alter type delivery_event_type add value
  'pod_submitted'` + `unique (delivery_request_id, pod_type)` em `proof_of_delivery`.
  **Nenhuma função** (evita o gotcha in-tx do enum-add-value).
- **Migration 0026** — 3 RPCs `SECURITY DEFINER`: `transition_delivery` **refinada**
  (assinatura inalterada — matriz ator×transição, limite de reatribuição, POD gate,
  cancelled/failed reason, `draft→cancelled` adicionado a M), `submit_proof_of_delivery`
  (driver-scoped ou system; valida completude + estado; insere POD; emite `pod_submitted`;
  **não transita**), `confirm_delivery` (**system-only** — `auth.uid() not null` →
  `not_authorized`; valida POD delivery + chama `transition_delivery('delivered')` que
  re-valida o gate; grant só `service_role`). Grants: `transition_delivery`/`submit_*`
  → service_role + authenticated (user-facing); `confirm_delivery` → service_role somente
  (authenticated sem EXECUTE — defesa em profundidade). **Nenhuma tabela/coluna nova.**
- **`supabase/tests/test_vio10_lifecycle.sql`** — 65 asserções (begin/rollback + SELECT
  consolidado). T1 happy path driver (assigned→in_transit + eventos + actor); T2 pulo de
  estado (invalid_transition); T3 driver não entrega (not_authorized); T4 driver não
  reatribui/cancela/falha; T5 business cancela pré-atribuição (draft/quoted/searching →
  cancelled; assigned → not_authorized); T6 admin pós-atribuição (cancel/fail/reassign +
  reassignment_count + no active); T7 system-only guard (admin bloqueado em
  quote/assign/expire; system executa); T8 limite de reatribuição metadata max:1
  (reassignment_limit_reached sem mutar, then failed); T9 reatribuição supersede
  (assignment superseded + ended_reason=reassigned + count++); T10 submit POD driver
  (submitted, sem transição, evento pod_submitted); T11 submit não-autorizado (driver
  sem assignment); T12 submit inválido (invalid_pod); T13 submit duplicado
  (pod_already_submitted); T14 submit wrong_state; T15 confirm system (delivered +
  delivered_at + evento); T16 confirm sem POD (pod_required); T17 confirm system-only
  (admin → not_authorized); T18 confirm wrong_state (picked_up → invalid_transition);
  T19 POD gate direto (system sem POD → pod_required); T20 pickup POD (sem transição);
  T21 cancel/fail reason de metadata; T22 draft→cancelled (business, nova transição em M).

### Decisões
- **Refinar `transition_delivery` (não criar N RPCs de domínio)**: a máquina de estados
  permanece um ponto único auditável; o app do driver chama `transition_delivery` com o
  status-alvo e a RPC autoriza por `auth.uid()`. Único acréscimo de RPC = POD (two-phase).
  Mantém o padrão do projeto (toda transição crítica por função central transacional).
- **POD two-phase (driver submete, sistema confirma)**: por causa da sutileza de
  `auth.uid()` em cadeia DEFINER (lê o JWT GUC, **não muda** com SECURITY DEFINER), um RPC
  driver-scoped não pode disparar uma transição system-only internamente. Logo o driver
  submete a evidência (`submit_proof_of_delivery`) e o sistema confirma
  (`confirm_delivery`, system-only). Espelha `create_quote`/`SWAC` (system-only,
  trust boundary). Em produção, **n8n** chama `confirm_delivery` (webhook sobre
  `pod_submitted`); pré-n8n, o backend/service layer chama.
- **`draft→cancelled` adicionado à matriz M**: business pode cancelar draft (ausente
  antes). Reatribuição tem teto configurável via metadata (sem tabela de config no MVP).
- **Callers internos preservados**: `create_quote` (system→draft→quoted ✓),
  `confirm_quote` (business/admin→quoted→searching_driver ✓) — matriz refinada não os
  quebra. `claim_delivery`/`select_winner_and_claim` não chamam `transition_delivery`
  — GATE da Sessão 10 permanece íntegro.

### Validado (real, no dev `rtoyfiqngyicqtuzwfhz` — nunca produção)
- **Reset from-scratch** via SQL + **replay 0001→0026 em ordem** — 26/26 limpo (sem
  MIGFAIL). `'pod_submitted'` referenciável em 0026 (split 0025/0026 resolve o gotcha
  in-tx do enum-add-value).
- Inventário: 26 tabelas (nenhuma nova), RLS 26/26, `proof_of_delivery` unique
  `(delivery_request_id, pod_type)`, enum `pod_submitted` presente, `transition_delivery`
  refinada (grant service_role+authenticated), `submit_proof_of_delivery` DEFINER (execute
  service_role+authenticated), `confirm_delivery` DEFINER **system-only** (execute só
  service_role, authenticated sem EXECUTE), `anon`=0 em `public`.
- `test_vio10_invariants.sql` → **13/13 PASS**; `test_vio10_rpcs.sql` → **48/48 PASS**;
  `test_vio10_authz.sql` → **21/21 PASS**; `test_vio10_auth_lifecycle.sql` → **34/34
  PASS**; `test_vio10_creation.sql` → **37/37 PASS**; `test_vio10_pricing.sql` → **62/62
  PASS**; `test_vio10_dispatch.sql` → **65/65 PASS**; `test_vio10_bid.sql` → **61/61
  PASS**; `test_vio10_lifecycle.sql` (novo) → **65/65 PASS** — todas reais (não simulado).
  **9/9 suítes, 406 asserções, zero falhas, sem regressão.**
- Veredito **GO → Sessão 12** (POD completo: foto/OTP/geolocation/recebedor).

### Corrigido (durante a validação real)
- **`test_vio10_rpcs.sql` TR8**: o POD gate novo (0026) faz `in_transit→delivered` exigir
  POD; o teste original não inseria POD antes da transição. Ajustado para inserir POD
  (owner path) antes de `transition_delivery('delivered')` — satisfaz o gate. 48/48 após.
- **Bug de teste — leak residual de JWT (não bug de RPC)**: `set_config(
  'request.jwt.claims',...,true)` é **is_local — persiste até o fim da TRANSAÇÃO, não do
  bloco**. A 1ª versão do `test_vio10_lifecycle.sql` setava JWT=driver em T1 e nunca
  resetava → T2's `mk_searching` rodava com `auth.uid()` = driver residual de T1 →
  `create_delivery_request` retornava `not_authorized` (driver não é membro org) → id
  null → `mk_assigned` null → `null value in column "dr_id"`. **Lição Sessão 06
  reconfirmada:** cada bloco de teste autenticado deve resetar o JWT para `'{}'`
  (system) **antes** dos helpers mk_*/create_*/confirm_quote (system path), depois setar
  o ator antes das chamadas autenticadas, e resetar de volta a `'{}'` antes de chamadas
  system-only dentro do mesmo bloco. Corrigido — 65/65 na 2ª execução. Diagnóstico
  exigiu captura do reason via temp table (RAISE NOTICE não alcança o resultset do
  endpoint — lição Sessão 03.5).

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