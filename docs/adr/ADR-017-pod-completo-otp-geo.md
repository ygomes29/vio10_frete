# ADR-017 — POD completo: OTP do recebedor, gate de geolocalização, gate de pickup POD, Storage (camada DB) + especificação da camada externa (n8n/WhatsApp)

- **Status**: Aprovado
- **Data**: 2026-08-28
- **Sessão**: 12

## Contexto

A Sessão 11 (ADR-016) fechou o **ciclo pós-`assigned` + POD gate de existência**:
`transition_delivery` refinada com matriz ator×transição, `submit_proof_of_delivery`
(driver-scoped, não transita), `confirm_delivery` (system-only), e o gate de **existência**
de POD delivery em `in_transit→delivered`. O que ficou deferido para Sessão 12 (verbatim de
`docs/DELIVERY_LIFECYCLE.md` / ADR-016):

> foto em Storage (URL assinada), geração/entrega de OTP ao recebedor via WhatsApp,
> validação de geolocalização, verificação do recebedor, gating de pickup POD em
> `picked_up`, auto-confirm orquestrado.

### Tensão de escopo (resolvida com o usuário)

ADR-016 defere a **orquestração n8n** (`pod_submitted → confirm_delivery`) para Sessões
13-14 e o **WhatsApp/DataCrazy** é Fase 8 (Sessões 15-16). O usuário optou por **"tudo
agora"**, mas o repositório **não tem camada de aplicação** (sem Next.js, sem n8n, sem
WhatsApp — apenas `supabase/` + `docs/`). Live-validar a entrega real via WhatsApp e o
workflow n8n é **impossível neste ambiente** (sem instância/provedor/credenciais), e a
regra mestra proíbe simular PASS ("Se não houver ambiente seguro disponível, declare
BLOCKED"). Decisão final do usuário: **"DB completo + especificar externa"** — construir a
camada DB/RPC completa e validá-la real no dev; **especificar** (docs + as RPCs que a camada
externa consome) a camada n8n/WhatsApp, marcando sua validação live como **deferida** (sem
simular PASS). Honra "tudo agora" no máximo viável sem violar a regra mestra.

### Estado atual (relevante, pós Sessão 11)

- `proof_of_delivery` (0011): `storage_path, otp_code (texto livre), receiver_name,
  location_point, notes`; unique `(delivery_request_id, pod_type)` (0025); RLS SELECT p/
  authenticated; writes só via DEFINER. **Sem coluna `verified`** (D8/Sessão 11 deferiu).
- `submit_proof_of_delivery` (0026): valida completude MVP, **não valida o OTP contra
  nada** (otp_code é texto livre). Não transita.
- `confirm_delivery` (0026, system-only): valida POD delivery existe → `transition_delivery
  ('delivered')`.
- `transition_delivery` (0026): gate de **existência** em `in_transit→delivered`.
  **Nenhum** gate de pickup POD. **Nenhum** gate de geolocalização.
- `delivery_requests` (0007): `pickup_point`/`delivery_point` `geography(Point,4326) NOT
  NULL` e `delivery_contact_phone text NOT NULL` (telefone do recebedor — alvo do OTP).
- Enum `delivery_event_type`: 22 valores (`pod_submitted` em 0025).
- **Nenhum bucket Storage** existe. Próximo slot: **0027**.

## Decisões

### D1 — Ciclo de vida do OTP em tabela dedicada `delivery_otps`

O OTP é **pré-gerado** (antes do submit): o sistema gera um código de 6 dígitos
(crypto-secure via `gen_random_bytes`), armazena **hash salt+sha256** (`pgcrypto`), com
`expires_at` (TTL default 900s), `max_attempts` (default 5), `attempts`, `consumed_at`.
Tabela `delivery_otps` com `unique (delivery_request_id)` — **delivery-only** (pickup não
tem recebedor; OTP é do recebedor da entrega).

- **Geração** é **system-only** via `generate_delivery_otp` (o driver **não** vê o código
  antes do recebedor); a RPC retorna o plaintext **apenas** ao caller system, que o envia
  via WhatsApp ao `delivery_contact_phone` (camada externa, D6).
- **Validação** acontece em `submit_proof_of_delivery` quando `pod_type='delivery'` e
  `otp_code is not null`: `select ... for update` em `delivery_otps` →
  `otp_not_generated` (sem OTP gerado) / `otp_expired` (now > expires_at) /
  `otp_max_attempts` (attempts ≥ max_attempts, locked) / `otp_already_used`
  (consumed_at set) / `otp_invalid` (hash não bate → `attempts++`, e se atingir max →
  `otp_max_attempts`). Match → `consumed_at = now()` **na mesma transação** do insert do
  POD (atomicidade; o unique `(delivery_request_id, pod_type)` já impede 2º POD).
- **Verificação do recebedor = OTP match.** Foto-only permanece aceito (either-or da
  completude MVP, D4) — o OTP é o mecanismo de verificação, a foto é evidência.
- **Hash**: `code_hash = encode(digest(code::bytea || salt::bytea, 'sha256'), 'hex')`,
  `salt = encode(gen_random_bytes(8), 'hex')`. Salt por linha derrota rainbow tables;
  resíduo aceito: 6 dígitos é brute-forceável por linha se o DB vazar, mitigado por
  TTL curto + lockout + acesso restrito (service_role). HMAC com secret de app exigiria
  um vault não disponível no MVP; salt+sha256 é o equilíbrio pragmático.
- **Regeneração** (upsert no unique): reseta `attempts=0`, `consumed_at=null`,
  `expires_at`, novo código/salt. O caller system pode regenerar se o recebedor não
  recebeu. Bloqueado se já existe POD delivery (estado `delivered`/POD já submetido) →
  `wrong_state` (a geração exige status em `('assigned','driver_to_pickup','at_pickup',
  'picked_up','in_transit')`).

### D2 — Gate de geolocalização (configurável, duro) em `in_transit→delivered`

Dentro de `transition_delivery`, **após** o gate de existência de POD delivery: lê
`v_tol := nullif(p_metadata->>'geo_tolerance_m','')::int`; default **200m** se null. Pega
`location_point` do POD delivery; se **presente**, `v_dist := st_distance(pod_loc,
delivery_point)`; se `v_dist > v_tol` → `(false, 'pod_geolocation_out_of_range')`.
Se o POD **não tem location** (GPS indisponível, submit OTP-only sem coords) → **skip**
do gate (não se pode validar o que não foi capturado; GPS de PWA é impreciso).

- **Residual documentado**: gate duro **quando** há localização; ausência de localização é
  aceita no MVP. Endurecer para **exigir** localização fica para sessão posterior (risco de
  falso-negativo em GPS ruim).
- `confirm_delivery` recebe `p_geo_tolerance_m int default null` e repassa em
  `metadata.geo_tolerance_m`, preservando o padrão "configurável via metadata" (igual a
  `max_reassignments`, ADR-016 D2). O orquestrador (n8n/backend) afina a tolerância por
  corrida (urbano denso vs rural).

### D3 — Gate de pickup POD em `at_pickup→picked_up` (espelha o gate de delivery)

`transition_delivery`: se `p_to_status='picked_up'` e não existe POD `pod_type='pickup'`
→ `(false, 'pickup_pod_required')`. O driver deve submeter um pickup POD (completude MVP:
`storage_path`/`otp_code`/`notes` ≥ 1) antes de marcar `picked_up`. Pickup POD continua
**não-transitando** (registrado apenas). Espelha o gate de delivery (D5/Sessão 11) —
defense in depth: o gate vive no ponto único (função central transacional), não nos callers.

### D4 — Verificação do recebedor = OTP; foto = evidência

Delivery POD com `otp_code` **DEVE** bater com um OTP gerado (D1); foto-only (sem otp) é
aceito mas **não verifica o recebedor** (evidência visual). Either-or **preservado**
(back-compat com Sessão 11); a profundidade Sessão 12 é: **se** `otp_code` vier, ele é
validado de verdade (não texto livre). Não se força OTP-only (quebraria o fluxo de foto);
a escolha do mecanismo fica com o caller/fluxo.

### D5 — Bucket Storage `pod-photos` (privado) + RLS INSERT p/ drivers com assignment ativa

- Migration cria `insert into storage.buckets (...)` (`public=false`,
  `file_size_limit=50MiB`, `allowed_mime_types=['image/png','image/jpeg']`) com guard
  `on conflict do nothing`.
- RLS policy INSERT em `storage.objects` p/ `authenticated`: path convencionado
  `pod-photos/{delivery_request_id}/{pod_type}/{uuid}.ext`; o policy verifica
  `exists(select 1 from delivery_assignments da join drivers d on d.id=da.driver_id
  where d.user_id=auth.uid() and da.delivery_request_id=(storage.foldername(name))[1]::uuid
  and da.status='active')`. **Sem** policy SELECT/UPDATE/DELETE p/ authenticated (reads via
  URL assinada emitida pelo backend/service_role; default-deny otherwise).
- **Validação comportamental de Storage RLS é DEFERIDA** — não é exercitável via curl
  `/database/query` (Storage é API separada; o endpoint DB roda como role management que
  bypassa RLS). Validação **estrutural** (bucket criado, policy existe em `pg_policies`)
  é feita no replay. A validação comportamental (upload-as-driver) fica para quando a
  Storage API for exercitável (Sessões 17-19 / frontend).

### D6 — Camada externa especificada, validação live DEFERIDA (não simular PASS)

- **`generate_delivery_otp`** (system-only, D1) — **construído e validado** (é DB): é a RPC
  que o backend consome para obter o código a enviar via WhatsApp.
- **Route Handler contract** `POST /api/internal/deliveries/{id}/confirm` (system-scoped,
  chama `confirm_delivery`) — **especificado** em `docs/N8N_WORKFLOWS.md` (a app Next.js
  não existe ainda; Sessões 17-19).
- **Workflow n8n** #13 (`entrega concluída`): trigger sobre evento `pod_submitted` (Realtime
  ou webhook) → chama o Route Handler de confirm (auto-confirm) — **especificado** em
  `docs/N8N_WORKFLOWS.md` (implementação Sessão 14).
- **Envio do OTP via WhatsApp/DataCrazy**: backend, ao entrar `in_transit` (ou ao
  atribuir), chama `generate_delivery_otp` → envia o código ao `delivery_contact_phone` via
  DataCrazy/WhatsApp — **especificado** em `docs/DATACRAZY_INTEGRATION.md` (nova seção
  receiver-OTP; Sessões 15-16).
- Todos marcados **"validação live deferida — requer n8n provisionado (Sessão 14) +
  WhatsApp provisionado (Sessões 15-16)"**. Honra "tudo agora" no máximo viável sem violar
  a regra mestra ("não simule PASS").

### D7 — Sem coluna `verified` (resolução do defer D8/Sessão 11)

Os gates (OTP match + geo + pickup) enforce **no momento da transição**; `delivered` só
acontece se todos passarem. Uma coluna `verified` no POD seria redundante. Schema mínimo:
**nenhuma** coluna nova em `proof_of_delivery`. Único acréscimo de tabela: `delivery_otps`.

### D8 — Split 0027/0028 (mesmo gotcha de `ALTER TYPE ADD VALUE` in-tx, ADR-016 D9)

Em PG, um valor de enum adicionado numa transação pode **não ser referenciável** na mesma
transação. Logo:

- **0027** (prep, **sem** função que referencie o novo enum): `alter type
  delivery_event_type add value 'otp_generated'`; `create table delivery_otps`; index;
  RLS + grants; bucket `pod-photos` + policies em `storage.objects`.
- **0028** (RPCs que referenciam `'otp_generated'`): `generate_delivery_otp` (nova),
  `submit_proof_of_delivery` (refinada — valida OTP), `confirm_delivery` (refinada —
  `p_geo_tolerance_m`), `transition_delivery` (refinada — pickup gate + geo gate).
  Assinatura de `transition_delivery` **inalterada** (callers preservados:
  `create_quote`/`confirm_quote`/`confirm_delivery`). `confirm_delivery` ganha um param
  com default (back-compat). `submit_proof_of_delivery` assinatura inalterada (usa
  `p_otp_code` existente).

### D9 — Ator via `auth.uid()`

- `generate_delivery_otp` **system-only** (auth.uid not null → not_authorized; execute só
  service_role — **5º system-only** após `create_quote`/`open_dispatch_round`/
  `select_winner_and_claim`/`confirm_delivery`). Ator system.
- `submit_proof_of_delivery` driver/system (inalterado). Ator driver ou system.
- `confirm_delivery` system-only (inalterado). Ator system.
- Eventos: `otp_generated` (novo enum, actor system) na geração; `pod_submitted`
  (existente) na submissão (metadata com `otp_consumed: true|false`); `delivered`
  (existente) na confirmação (metadata com `pod_id`).

## Consequências

- **Schema**: +1 tabela (`delivery_otps`), +1 valor de enum (`otp_generated`), +1 bucket
  Storage (`pod-photos`) + 2 policies em `storage.objects`, +1 RPC nova
  (`generate_delivery_otp`), 3 RPCs refinadas (`submit_proof_of_delivery`,
  `confirm_delivery`, `transition_delivery`). Assinatura de `transition_delivery`
  inalterada (callers internos preservados); `confirm_delivery` +1 param default.
- **Grants**: `generate_delivery_otp` execute só `service_role` (system-only);
  `submit_proof_of_delivery` inalterado (service_role + authenticated);
  `confirm_delivery` inalterado (service_role); `transition_delivery` inalterado.
  `delivery_otps`: SELECT p/ authenticated (RLS visibilidade), writes via DEFINER.
- **Validação**: DB/RPC validado real no dev (28/28 replay, 10 suítes). Storage RLS
  comportamental + camada n8n/WhatsApp **deferidos** (declarado, não simulado).
- **Regressão**: o gate de pickup (D3) quebra testes existentes que fazem `picked_up`
  sem pickup POD — corrigido nos testes (`test_vio10_lifecycle.sql` T1/T3/T10-T20 +
  `test_vio10_rpcs.sql` TR6 adicionam pickup POD). O gate de geo (D2) **não** quebra tests
  existentes (submetem POD sem location → skip).

## Fora do escopo (adiado)

- **Live n8n** (workflow implementado, instância provisionada) → Sessão 14.
- **Live WhatsApp/DataCrazy** (OTP entregue de verdade) → Sessões 15-16.
- **App Next.js** (Route Handlers, frontend) → Sessões 17-19.
- **Storage RLS comportamental** (upload-as-driver) → Sessões 17-19 (frontend/Storage API).
- **Exigir location no delivery POD** (endurecer geo gate de skip→hard-required) → sessão
  posterior (MVP skip quando sem GPS).
- **OTP de pickup** (recebedor na coleta) → não há recebedor no pickup; fora.
- **Coluna `verified`** no POD → D7: não necessária.
- **Reporte de issue pelo driver** → Sessão 12+ (não abordado).
- **Hardening do lock-ordering** (dívida ADR-015 D4) → independente; deferido.