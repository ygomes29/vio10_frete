# ADR-019 — Camada de API: Next.js Route Handlers (contract surface ADR-018 D5)

- **Status**: Aprovado
- **Data**: 2026-08-29
- **Sessão**: 14 (revisada — pivot n8n → API layer)

## Contexto

A Sessão 13 (ADR-018) fechou o **design** do n8n e enumerou a **contract surface** que o
n8n (e os apps) consomem: 12 endpoints mapeando a 11 RPCs centrais (D5). A Sessão 14 como
escrita no roadmap (implementar n8n numa instância provisionada) está **BLOCKED**: não há
instância n8n, nem Route Handlers (Sessões 17-19), nem WhatsApp (Sessões 15-16); a regra
mestra proíbe simular PASS. O usuário escolheu **pivotar Sessão 14 para a camada de API**
— a camada que n8n **e** os apps consomem, e que a regra de execução do projeto
("backend → regras → APIs → ...") indica como a próxima buildable agora que o
backend+regras (Sessões 03-12, 28 migrations, 10/10 suítes PASS) está validado.

### O que existe hoje no repositório

`supabase/` (28 migrations, RPCs `SECURITY DEFINER` validados real no dev) + `docs/` (mãe
+ ADR-001 a ADR-018). **Não há camada de aplicação.** O que existe é o **contrato** — a
superfície de endpoints que realiza o mapeamento ADR-018 D5, e os RPCs que são a fonte da
verdade. A Sessão 14 (revisada) constrói a **fundação Next.js 16.3.3** + os Route Handlers
**system/internal** que realizam esse contrato, com validação real contra o dev onde as
chaves permitirem (regra mestra: não simular PASS).

### Princípios herdados (regra mestra + ADRs)

- **Banco é a fonte da verdade. Backend decide.** Route Handler é fino; a lógica de
  negócio fica nos RPCs `SECURITY DEFINER` (já validados). Nenhum estado operacional/
  financeiro é mutado fora da RPC central transacional.
- **`service_role` nunca vaza** ao client/browser/n8n/IA (ADR-018 D1). Vive só server-side
  dentro do handler.
- **5 RPCs system-only** (`create_quote`, `open_dispatch_round`, `select_winner_and_claim`,
  `confirm_delivery`, `generate_delivery_otp`): `auth.uid() is not null → not_authorized`;
  `execute` só a `service_role`. Exigem system-client server-side, nunca expostos ao n8n.
- **ACEITAR ≠ GANHAR** (ADR-006): `select_winner_and_claim` (SWAC) decide + chama
  `claim_delivery` atomicamente (GATE Sessão 10). n8n **não** decide atribuição — só pede
  o close; `claim_delivery` é interno ao SWAC, **sem endpoint**.
- **POD/OTP two-phase** (ADR-017): `generate_delivery_otp` (5º system-only) retorna
  plaintext **só** ao caller system; `submit_proof_of_delivery` valida OTP; `confirm_delivery`
  (system-only) → `transition_delivery('delivered')` re-valida gates.
- **Idempotência R17** (3 conceitos distintos, não misturar): `idempotency_key` → retry
  dedup (`integration_events`); `external_event_id` → inbound dedup; `external_reference`
  → criação dedup (interno da `create_delivery_request`, on conflict 0021:140);
  `correlation_id` → só propagação/log.
- **Trust boundary do pricing** (ADR-012 D2): distância/duração vêm do **provider**
  (plataforma), nunca do business; nunca haversine para pricing.

## Decisões

### D1 — Route Handler é fino; service layer detém a lógica de orquestração

Handler: parse HTTP → `requireInternal` → delega ao service → map resultado → HTTP.
Service (uma fn por operação): validate input → idempotency ledger → chamar RPC via client
certo → mapear `(ok, reason, ...)` → `RpcResult`. Regras de negócio **não** no handler
(BACKEND §2). O fluxo padrão é consolidado em `handleInternalPost`
(`lib/api/internal-handler.ts`): internal-auth → parse JSON → validate (pré-claim) →
idempotency ledger → RPC → map → HTTP. Validação roda **antes** do claim — falha de input
**não** vira replay (uma correção com novo payload não deve colidir com o claim inválido
anterior).

### D2 — Dois clients, dois scopes

- `createServerClient()` (`lib/supabase/server-client.ts`, `@supabase/ssr`): **user-scoped**.
  Lê JWT do cookie da requisição (ADR-010 D5/D6: cookie-based, JWT DB-lookup, sem custom
  claims). RLS aplica; `auth.uid()` é o usuário autenticado. Para operações de
  usuário/driver (Sessão 15).
- `createSystemClient()` (`lib/supabase/system-client.ts`): **system-scoped**, `service_role`,
  `import "server-only"`, singleton cacheado, `auth:{persistSession:false,autoRefreshToken:false}`.
  RLS bypass; `auth.uid()` null. Para os 5 RPCs system-only e escrita do idempotency ledger.

**`service_role` nunca exposto ao client/browser/n8n/IA** — vive só server-side dentro do
handler. n8n autentica por shared secret (D3), não por `service_role`.

### D3 — System-callers (n8n) autenticam por shared secret, não por service_role

Header `x-internal-api-key` vs `INTERNAL_API_KEY` env, comparado em tempo constante
(`crypto.timingSafeEqual`, `lib/supabase/internal-auth.ts`). Verificado → handler usa
`createSystemClient()` internamente. Sem o secret → 401. **Fail-closed**: se
`INTERNAL_API_KEY` não está configurado, recusa tudo (nunca deixar system endpoints abertos
por ausência de config). MVP: shared secret via env; mTLS/IP-allowlist + rotação →
hardening Sessão 22/26. `service_role` **nunca** vaza ao n8n (ADR-018 D1).

### D4 — Idempotency ledger é responsabilidade da camada de API (service layer)

Exceto `respond_to_offer` (idempotência interna no RPC, Sessão 09), **nenhum RPC escreve
`integration_events`**. O service layer (`lib/idempotency/ledger.ts`) claima antes da RPC
mutante: `select → upsert(ignoreDuplicates onConflict source,<col>) → re-select` (resolve
race concorrente). Conflito com `result` gravado = **replay** (retorna o resultado
cacheado, **não** re-executa); `pending` sem `result` = **in_flight** → 409; sem chave de
dedup = **skip** (prossegue direto — os guards da RPC `wrong_state`/`round_already_open`
protegem). `idempotency_key` tem precedência sobre `external_event_id`; `onConflict`
acompanha a coluna em uso (ambas têm unique `(source, <col>)`). Ledger é system-only
(grant só a `service_role`, 0015 — `authenticated` sem grant). O ledger é **defesa em
profundidade + replay explícito + auditoria**; o guard real de criação é a RPC
(`external_reference` on conflict).

### D5 — Provider atrás da abstração; /quote e /enrich 501 até Sessão 20

Interfaces `GeocodingProvider`/`RoutingProvider` (ADR-005) definidas
(`lib/providers/*.ts`), **nenhuma impl registrada** (registry vazio). `POST /deliveries/{id}/quote`
e `POST /deliveries/{id}/enrich` são shells completos: detectam "provider não configurado"
→ **501 `geo_provider_not_configured`** (corpo claro), via `ProviderNotConfiguredError`
carregando `status`/`reason` (mapeado no handler). **Não** usar distância em linha reta
(haversine) para pricing — violaria ADR-012 D2; o provider real (Google Maps
`TWO_WHEELER`) é Sessão 20. Trust boundary do pricing preservado: distância/duração vêm do
provider, não do business. **Não simulado** (regra mestra).

### D6 — Mapeamento de resultado da RPC → HTTP

`(ok=true) → 200` + corpo com ids; replay (`reason=idempotent_replay`) → **200** (sucesso
cacheado, não 409); `(ok=false, reason)` → 4xx mapeado (`lib/rpc/result.ts`):
`not_authorized`→403, `invalid_param`→400, `wrong_state`/`round_already_open`/
`round_not_open`/`already_responded`/`otp_already_used`→409, `not_found`/`delivery_not_found`/
`no_pricing_rule`/`pod_required`/`pickup_pod_required`/`pod_geolocation_out_of_range`/
`otp_*`→422, reason desconhecido→422 (backend respondeu, não erro de transporte); erros
inesperados (exceção do PostgREST) → 500 + log `correlation_id`. Nunca vazar stack trace.

### D7 — Auth user-scoped mínima agora; middleware full na Sessão 15/17

`@supabase/ssr` server client lê cookie → `getUser()`. Para esta sessão, os endpoints
system/internal são o foco (internal-auth, não cookie). A wiring completa de
cookie/refresh/middleware (ADR-010 D6) vai com os endpoints driver/user-facing na Sessão 15.

### D8 — Logs sem secrets, PII minimizada (ADR-018 D10)

`correlation_id`, `delivery_request_id`, `organization_id`, origem, resultado. **Nunca**
`service_role`, `INTERNAL_API_KEY`, nem plaintext OTP nos logs. O handler `/otp` é
`sensitive: true` — o `payload` não é gravado no ledger e o `otp_code` da resposta não é
logado (ADR-017 D1).

### D9 — Validação real onde as chaves permitirem; nunca simular PASS

Step 0 = recuperar chaves do dev (anon + service_role) via Management API. Se recuperáveis:
`next dev` + curl exercita o vertical slice (create → confirm-quote → open round →
close/SWAC → assigned; + OTP → POD → confirm-delivered), estado e `delivery_events`
verificados via curl + Management API `/database/query` (padrão Sessões 03-12); idempotência:
repetir call com mesmo `Idempotency-Key` → replay (sem efeito duplicado). Regra mestra: o
que rodou live = PASS; o que não pôde rodar (sem provider, sem WhatsApp) = declarado
BLOCKED/deferred (não PASS). Não simular.

## Superfície de endpoints (realização ADR-018 D5)

| Endpoint | RPC | Scope |
|---|---|---|
| `POST /api/internal/deliveries` | `create_delivery_request` | system (internal-auth) |
| `POST /api/internal/deliveries/{id}/quote` | `create_quote` | system (501 até Sessão 20) |
| `POST /api/internal/deliveries/{id}/enrich` | (geocoding) | system (501 até Sessão 20) |
| `POST /api/internal/deliveries/{id}/confirm-quote` | `confirm_quote` | system (internal-auth) |
| `POST /api/internal/deliveries/{id}/dispatch/rounds` | `open_dispatch_round` | system-only |
| `POST /api/internal/dispatch/rounds/{id}/close` | `select_winner_and_claim` | system-only |
| `POST /api/internal/deliveries/{id}/confirm` | `confirm_delivery` | system-only |
| `POST /api/internal/deliveries/{id}/otp` | `generate_delivery_otp` | system-only (sensitive) |
| `POST /api/internal/deliveries/{id}/transitions` | `transition_delivery` (actor=system) | system (internal-auth) |

`claim_delivery` é **interno ao SWAC** — sem endpoint (GATE Sessão 10, ADR-018 D9).

**Deferido para a Sessão 15**: endpoints driver/user-facing (`respond_to_offer`,
`submit_proof_of_delivery`, transitions driver-side via JWT + signed links), webhook
router (`/api/webhooks/datacrazy`), cookie/middleware full.

## Consequências

- A contract surface ADR-018 D5 passa de **design** para **código** (system/internal subset).
- `service_role` encapsulado server-side; n8n autentica por shared secret (fronteira
  preservada).
- Idempotency ledger dá replay explícito + auditoria além dos guards de RPC.
- `/quote` e `/enrich` 501 (não simulados) — trust boundary do pricing intacto até a
  Sessão 20.
- Validação live do vertical slice confirma o encadeamento real (create→…→assigned→
  delivered) pela primeira vez fora do SQL — base para n8n (Sessão 14 original, reabre) e
  apps (Sessões 15-19).

## Fora do escopo (adiado)

- Endpoints driver/user-facing + webhook router DataCrazy + cookie/middleware full → **Sessão 15**.
- Provider Google Maps real (`/quote`, `/enrich` end-to-end) → **Sessão 20**.
- Implementação n8n (instância provisionada) → reabre quando Route Handlers + WhatsApp existirem.
- mTLS/IP-allowlist + rotação do internal secret → Sessão 22/26.