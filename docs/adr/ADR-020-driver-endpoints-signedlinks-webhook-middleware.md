# ADR-020 — Endpoints driver/user-facing, signed links, webhook router, cookie/middleware full

- **Status**: Aprovado
- **Data**: 2026-08-29
- **Sessão**: 15

## Contexto

A Sessão 14 (revisada, ADR-019) entregou a camada de API **system/internal** — os Route
Handlers que o n8n consome (9 endpoints, internal-auth por shared secret, idempotency
ledger, service layer, provider abstraction 501). A ressalva explícita era: os endpoints
**driver/user-facing** (`respond_to_offer`, `submit_proof_of_delivery`, transitions
driver-side via JWT+signed links), o **router de webhooks DataCrazy** (inbound) e a
**wiring completa de cookie/refresh/middleware** (ADR-010 D6) ficaram para a Sessão 15.
Junto, isto fecha a **contract surface** do ADR-018 D5.

**Nenhuma migration/RPC/enum/grant novo.** Os 3 RPCs driver-facing — `respond_to_offer`
(0016), `submit_proof_of_delivery` (0028), `transition_delivery` (0028) — e
`set_driver_availability` (0016) são **finais e validados** desde as Sessões 09-12, com
`execute` a `authenticated`+`service_role` e ator resolvido de `auth.uid()` (Modelo B,
ADR-009/010). A Sessão 15 é **camada de aplicação pura**: Route Handlers + service layer +
middleware + signed links. Reusa toda a fundação da Sessão 14
(`createServerClient`/`createSystemClient`/`internal-auth`/`callRpc`/`toApiResponse`/
`getCorrelationId`/`getIdempotencyHeaders`/`jsonResponse`/`logEvent`/`withIdempotency`).

### Decisões do usuário (AskUserQuestion)

- **Signed link = token HMAC system-scoped** (não mintar JWT real do driver). O handler
  verifica o token e chama `respond_to_offer` **system-scoped** (`auth.uid()` null,
  `p_driver_id` do token). O binding (offer,driver)+expiração **é** a autorização.
- **Escopo = completo**: 3 endpoints nomeados (respond, transitions, pod) + generator do
  signed link + toggle de disponibilidade.

## Decisões

### D1 — Dois modos de auth nos endpoints driver; um handler dual-auth no respond

- **Cookie JWT** (PWA logado): `createServerClient()` (flavor `@supabase/ssr`,
  `cookies()` de `next/headers`) lê o cookie → `getUser()` → **401 se null**. A RPC roda
  **user-scoped** (`auth.uid()` = driver; a RPC resolve o ator e verifica posse
  internamente — Modelo B). Usado em: transitions driver, submit_pod, set_availability,
  e o respond logado.
- **Signed link HMAC** (WhatsApp, sem login): token HS256 `{o:offerId, d:driverId,
  e:exp, n:nonce}` assinado com `ACTION_LINK_SIGNING_SECRET`. O handler verifica HMAC
  (timing-safe) + `exp > now` + `o === path id` (proteção IDOR); chama `respond_to_offer`
  **system-scoped** (`auth.uid()` null, `p_driver_id` do token). O binding (offer,driver)
  +expiração **é** a autorização — não minta JWT real. Replay rejeitado pela idempotência
  **interna** da RPC (`(offer,driver)` unique → uma resposta válida por par). Especificado
  em `docs/SECURITY.md` §423-428 (constraints) e `docs/DATACRAZY_INTEGRATION.md`.
- `POST /api/offers/{id}/respond` é **dual-auth** (`handleOfferRespondPost`): se cookie
  JWT válido → user-scoped (body traz `driver_id`, RPC verifica `drivers.user_id=auth.uid()`);
  senão se `?token=` ou header `x-offer-token` válido → signed-link system-scoped; senão →
  **401**. Ordem: cookie primeiro (PWA preferencial), token como fallback (WhatsApp).

### D2 — Service layer driver aceita `client`; o handler decide o escopo

Service fns em `lib/services/driver.ts` recebem `client: SupabaseClient` (não criam o
próprio): o handler passa `createServerClient()` (cookie, user-scoped) ou
`createSystemClient()` (token, system-scoped). `callRpc` é client-agnostic (Sessão 14
confirmou). RPCs user-scoped resolvem `auth.uid()` internamente:
- `transition_delivery` user-scoped ignora `p_actor_type`/`p_actor_id` (resolve do JWT;
  passamos `p_actor_type='driver'` só p/ documentar intent — a RPC sobrescreve).
- `respond_to_offer` user-scoped verifica posse via `auth.uid()`.
- `set_driver_availability` é **void + raise exception** `'not_authorized'` (não segue o
  padrão `returns table(ok,reason)`); logo **não usa `callRpc`** — o service chama
  `client.rpc(...)` direto e mapeia a exception → `{ok:false, reason:'not_authorized'}` (→403).

### D3 — Signed link: HMAC-SHA256, payload compacto, TTL configurável

`lib/auth/signed-link.ts` (`import "server-only"`):
- `createActionLink({offerId, driverId, ttlSeconds?})` → `{token, expiresAt}`.
- `verifyActionLink(token, expectedOfferId?)` → `{offerId, driverId, exp} | null`.
- Token = `base64url(payload) + "." + base64url(hmac_sha256(payload))`. Payload
  `{o, d, e, n}` (uuids curtos, exp epoch, nonce anti-replay de geração).
- Secret `ACTION_LINK_SIGNING_SECRET` (env novo; **fail-closed** se ausente → não gera nem
  verifica links — `getSecret()` lança, `verifyActionLink` retorna null).
- TTL default **900s** (alinhado à janela da rodada, `response_window_seconds` n8n #5).
- IDOR-protegido pelo binding (offer,driver); replay pela idempotência **interna** da RPC.
- Comparação timing-safe da assinatura (`timingSafeEqual`).

### D4 — Generator do signed link é endpoint system/internal (n8n #6 o chama)

`POST /api/internal/offers/{id}/respond-link` (internal-auth `x-internal-api-key`): body
`{driver_id, ttl_seconds?}` → `{token, url, expires_at}`. n8n workflow #6 embbe a URL na
mensagem WhatsApp (ACEITAR/RECUSAR/FAZER LANCE apontam para `POST /api/offers/{id}/respond`).
Sem este generator o fluxo WhatsApp não fecha. Reusa `handleInternalPost` (system, **sem
ledger** — geração de token é pura, não muta banco, idempotência irrelevante).
`NEXT_PUBLIC_APP_URL` (env) é a base pública da URL do link.

### D5 — Webhook router DataCrazy: signature + dedup via `webhook_events` + routing

`POST /api/webhooks/datacrazy` (público, sem JWT, protegido por signature):
1. Verifica signature — HMAC-SHA256 do **raw body** com `DATACRAZY_WEBHOOK_SECRET`, header
   `x-datacrazy-signature` (hex), comparada em tempo constante. **Fail-closed** se secret
   ausente → recusa tudo. Inválida → **401 discard**.
2. `external_id` obrigatório (header `x-datacrazy-event-id`) — chave de dedup. Ausente → 400.
3. Dedup via `webhook_events (source='datacrazy', external_id)` UNIQUE — upsert
   `onConflict: "source,external_id", ignoreDuplicates: true`. Duplicado → **200
   `idempotent_replay`** (não re-roteia).
4. Parse do intent (payload estruturado pela IA; campo `intent`). Roteia:
   - `offer_response` → `respondToOffer(system, ...)` (system-scoped; driver_id do payload).
   - `new_request` → `createDelivery(...)` (Sessão 14 service).
   - `otp_request` → `generateOtp(...)` (Sessão 14 service).
   - desconhecido → throw → handler marca `failed` + 200 `routed_with_error` (DLQ; IA
     re-pergunta ou n8n reconciler).
5. **200 sempre** ao emissor (webhook não pode depender de parsing caro); erros logados
   com `correlation_id` + `webhook_events.status='failed'`. Reconciler/DLQ backstop
   (ADR-018 D7). Per ADR-018 #16 + SECURITY §454. `external_event_id`→`webhook_events.external_id`
   (R17 inbound). `webhook_events` é service-only (escrita via system client).

### D6 — Cookie/middleware full (ADR-010 D6, @supabase/ssr 0.12.5)

- `lib/supabase/middleware-client.ts` (**SEM `server-only`** — middleware tem runtime
  próprio): factory `createMiddlewareClient(request, response)` — `getAll` lê
  `request.cookies.getAll()`, `setAll` escreve `response.cookies.set()` (o flavor middleware
  do @supabase/ssr; distinto do `server-client.ts` que usa `cookies()` de `next/headers`
  com `setAll` no-op em Server Components). O `setAll` real na borda é o que faz o refresh
  de token chegar ao browser.
- `middleware.ts` reescrito: refresh de sessão server-side — `getUser()` (dispara refresh se
  o access token expirou; cookies novos gravados na `response` via `setAll`) → protege
  paths `/driver`, `/admin`, `/business` (sem sessão → **307 `/auth/login`** (default de
  `NextResponse.redirect`, validado live) com
  `?redirect=`). Libera `/api/*` (Route Handlers fazem auth própria — internal-auth p/
  system, cookie/JWT p/ user), `/auth/*` (login) e estáticos via matcher. Página placeholder
  `app/auth/login/page.tsx` (UI nas Sessões 17-19).
- `lib/supabase/server-client.ts`: o `setAll` no-op atual fica (Server Components read-only);
  o refresh real na borda é no middleware. ADR-010 D6 já tem
  `enable_refresh_token_rotation=true` no `config.toml`.

### D7 — Idempotência: ledger só onde aplica; RPCs user-facing usam guards internos

- `respond_to_offer`: idempotência **interna** (`bids.idempotency_key` + `(offer,driver)`
  unique; `already_responded`/`idempotent_replay`). **Não** usa `withIdempotency`/
  `integration_events` (exceção ADR-019 D4 reconfirmada). Header `Idempotency-Key` vira
  `p_idempotency_key`.
- `submit_proof_of_delivery`/`transition_delivery`/`set_driver_availability`: sem
  `idempotency_key` param; idempotência via `unique(delivery_request_id,pod_type)` /
  máquina de estados / posse. **Sem ledger.** Retry seguro (state guards).
- Webhook router: dedup via `webhook_events` (D5), **não** `integration_events`.
- `correlation_id` → só log/propagação (R17). Não misturar
  `idempotency_key`/`external_event_id`/`external_reference`/`correlation_id`.

### D8 — Mapeamento RPC→HTTP estendido (`lib/rpc/result.ts`)

Adicionado a `reasonToStatus`: `unauthenticated`→**401**, `offer_expired`→**410** (gone),
`offer_already_responded`/`round_not_open`/`delivery_not_searching`/`pod_already_submitted`/
`already_responded`/`invalid_transition`/`reassignment_limit_reached`/`otp_already_used`→**409**,
`offer_not_found_for_driver`→**404**, `invalid_bid_amount`/`invalid_response_type`/
`invalid_pod`→**400**. `set_driver_availability` raise `'not_authorized'` → service mapeia
para `RpcResult{ok:false,reason:'not_authorized'}` → **403** via `reasonToStatus`. Replay
idempotente (`idempotent_replay`) continua **200** (não 409).

### D9 — Logs sem secrets; PII minimizada (ADR-018 D10)

`correlation_id`, ids, origem, resultado. Nunca `service_role`,
`ACTION_LINK_SIGNING_SECRET`, `DATACRAZY_WEBHOOK_SECRET`, `INTERNAL_API_KEY`, nem
plaintext OTP nos logs. Endpoint `/pod` é `sensitive: true` (não loga `otp_code`/payload).

### D10 — Sem migration/RPC/grant novo

Sessão 15 é camada de aplicação. Re-confirma regressão 10/10 (nada tocou o DB). Validar
real no dev; não simular PASS. Os 4 RPCs driver-facing são finais desde Sessões 09-12.

## Consequências

- A **contract surface** do ADR-018 D5 fecha: 9 endpoints system/internal (Sessão 14) +
  5 endpoints driver/user-facing + 1 webhook router + 1 generator de link (Sessão 15).
- `service_role` nunca vaza ao client/n8n/IA/DataCrazy (regra mestra íntegra): signed link
  system-scoped só para `respond_to_offer`; webhook só escreve `webhook_events`
  (service-only) e chama services; endpoints user-facing usam client user-scoped (cookie).
- ACEITAR ≠ GANHAR (ADR-006) preservado: `respond_to_offer` **não atribui**; SWAC decide.
- Submetir POD ≠ entregue (ADR-017) preservado: `submit_proof_of_delivery` não transita;
  `confirm_delivery` (system) transita p/ `delivered`.
- Middleware protege as route groups futuras (Sessões 17-19); hoje nenhuma página
  existe sob `/driver`/`/admin`/`/business`, então o redirect é forward-looking.

## Ressalvas (declarado, não PASS — regra mestra)

- **UI PWA/dashboards/portal** (Sessões 17-19): só placeholder de login. Nenhum fluxo
  user-facing exercitado por UI real.
- **DataCrazy/WhatsApp outbound real** (Sessão 16): Sessão 15 só o **inbound** webhook
  router + generator de link. O n8n embutindo a URL na mensagem é Sessão 16.
- **Provider Google Maps real** (Sessão 20): `/quote`+`/enrich` continuam 501
  (`geo_provider_not_configured`).
- **Storage upload de foto do POD via API**: o PWA fará upload direto ao bucket
  `pod-photos` (RLS `pod_photos_insert` Sessão 12); `submit_pod` recebe só `storage_path`.
  Live-validação de Storage RLS comportamental continua deferida (Sessões 17-19).
- **n8n implementação live** reabre com Route Handlers + WhatsApp (Sessão 16 + reabertura n8n).
- Rate limiting, mTLS, rotação de secret (Sessão 22/26).

## Verificação

1. **Typecheck + unit tests vitest**: `tsc --noEmit` clean; **124/124** tests PASS
   (signed-link, user-handler, offer-respond-handler dual-auth, webhook-auth/handler,
   driver services/validators, result extensions, + Sessão 14 regressão).
2. **Regressão DB** (nada mudou): reset via SQL + replay 0001→0028 limpo (28/28); 10/10
   suítes PASS (zero regressão) — confirma que Sessão 15 não toca o backend.
3. **Live vertical slice** `next dev`+curl (dev, chaves de `.env.local`) — ver plano.
4. **Veredito**: o que rodou live = PASS; o que não pôde (UI/WhatsApp outbound/Storage
   comportamental) = declarado deferred (não PASS).