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

Implementadas na Sessão 03 (`supabase/migrations/0013_rpcs.sql`) e convertidas para
`SECURITY DEFINER` com checagem interna de `auth.uid()` na Sessão 04
(`0016_rpcs_security_definer.sql`, Modelo B / ADR-009), com `search_path` fixo.
**Por que DEFINER:** com INVOKER + grants de DML a `authenticated`, um motorista logado
poderia mutar estado via PostgREST direto, furando a máquina de estados. DEFINER roda
como owner e valida posse do caller via `auth.uid()` (null=system, permite; não-null=user,
valida). `authenticated` não recebe DML de domínio — só EXECUTE nas RPCs + SELECT sob RLS.

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

Ainda não implementado (Sessão 10): harness de **concorrência real** de
`claim_delivery`/`select_winner_and_claim` (dois claims paralelos via `dblink`/advisory
lock) — gate formal de produção (ADR-007). A seleção pontua/ordena candidatos e chama
`claim_delivery` via `select_winner_and_claim` (§4.5, Sessão 09); a atomicidade
funcional já é testada.

### 4.1 RPCs de identidade / convite (Sessão 05, ADR-010)

Implementadas em `supabase/migrations/0018_handle_new_user.sql` (trigger) e
`0019_invitations_roles.sql` (tabela + 6 RPCs + helpers). Seguem o **Modelo B**:
`SECURITY DEFINER` + checagem interna de `auth.uid()`; `authenticated` sem DML
direto em `invitations`/`user_platform_roles`/`organization_memberships`/`drivers`
— só EXECUTE nas RPCs + SELECT em `invitations` sob RLS; `anon` nada.

- **`handle_new_user()`** (trigger `SECURITY DEFINER` on `auth.users` AFTER INSERT):
  cria a linha em `profiles(id = new.id, full_name/phone de new.raw_user_meta_data)`
  com `on conflict (id) do nothing`. **Garante a FK** de
  `user_platform_roles`/`organization_memberships`/`drivers` → `profiles(id)`
  independentemente do caminho (signup direto, convite aceito, provisionamento
  admin). **Não** atribui papel/membership/driver — isso é ato explícito via 0019.
  Padrão Supabase.
- **`create_invitation(p_email, p_role_type, p_organization_id, p_driver_meta)`** —
  inviter autorizado cria um convite `pending` com `token`. **Não** cria `auth.users`
  (o signup via Supabase Auth Admin API é responsabilidade do backend, fora do
  escopo DB). Authz do inviter conforme matriz ADR-010 D7 (`is_super_or_admin()` para
  papéis platform/driver; `business_owner` da própria org para `business_*`).
- **`accept_invitation(p_token)`** — caller **autenticado** cujo email casa com
  `invitations.email` (prova propriedade do email via login; `anon` não acessa).
  Aplica o papel **idempotentemente** (`on conflict do nothing`); aceitar 2x →
  `already_accepted` (não duplica). Marca `accepted`. Rejeita expirado
  (`expires_at < now()` → `expired`) e já accepted.
- **`cancel_invitation(p_invitation_id)`** — inviter ou admin. Só `pending`→`cancelled`.
- **`assign_platform_role(p_user_id, p_role)`** — `super_admin`/`admin` (via
  `is_super_or_admin()`). Idempotente (upsert).
- **`add_org_member(p_user_id, p_organization_id, p_role)`** — `super_admin`/`admin`
  **ou** `business_owner` da própria org. Idempotente (`UNIQUE(user_id, organization_id)`).
- **`create_driver(p_user_id, p_full_name, p_phone)`** — `super_admin`/`admin`. Insert
  em `drivers` (`account_status` default `pending`). Idempotente (`already_exists`).

**Visibilidade vs. autoridade (ADR-010 D4.1):** a RLS de *visibilidade* de
`invitations` usa `is_platform_admin()` (inclui `operator` — despacho cross-tenant,
ADR-009). As 4 RPCs de **mutação** usam `is_super_or_admin()` (`super_admin`/`admin`,
**exclui** `operator`) — reusar `is_platform_admin()` em mutação seria escalonamento
de privilégio. Helper `my_email()` (DEFINER) resolve o email do caller para
`accept_invitation` sem expor `auth.users` ao `authenticated`.

**Ainda não implementado (Sessão 06+ offboarding):** `remove_platform_role`,
`remove_org_member` (revogação de papel/membership) e limpeza assíncrona de
convites expirados. `accept_invitation` já rejeita expirados; o modelo suporta
revogação futura (delete em memberships). O lado **driver** do offboarding já existe
via `update_driver_status` (ver §4.2).

### 4.2 RPCs de gestão de entidades + criação da corrida (Sessão 06, ADR-011)

Implementadas em `supabase/migrations/0020_management_rpcs.sql` (6 RPCs) e
`0021_create_delivery_request.sql` (1 RPC). **Modelo B**: `SECURITY DEFINER` +
checagem interna de `auth.uid()`; `authenticated` **sem DML** em
organizations/businesses/business_locations/vehicles/delivery_requests — só EXECUTE
nas RPCs + SELECT sob RLS (0017); `anon` nada. **Nenhuma tabela nova**; único schema
change: `create unique index idx_vehicles_plate_uk on public.vehicles(plate)` (0020).

- **`create_organization(p_name, p_legal_name, p_document)`** → `(ok, reason,
  organization_id)`. Provisionamento de tenant. Authz: `is_super_or_admin()` ou system
  (null). Sem chave natural — cada chamada cria um org; dedup é do serviço.
- **`create_business(p_organization_id, p_name)`** → `(ok, reason, business_id)`.
  Authz: `is_super_or_admin()` **ou** `business_owner` da própria org (via
  `organization_memberships`). Valida org existe.
- **`create_business_location(p_business_id, p_label, p_address, p_latitude,
  p_longitude, p_contact_name, p_contact_phone)`** → `(ok, reason,
  business_location_id)`. `set search_path = public, extensions, pg_catalog`.
  Resolve org do business; authz business_owner da org ou admin. Monta `point`
  (`geography`) via PostGIS se lat/lng ambos presentes; respeita o CHECK "ambos null
  ou ambos set" do schema (`invalid_latlng` se parcial).
- **`create_vehicle(p_driver_id, p_vehicle_type, p_plate, p_model, p_capacity_kg)`**
  → `(ok, reason, vehicle_id)`. Veículos **driver-owned**. Authz: **driver self**
  (`drivers.user_id = auth.uid()` de `p_driver_id`) **ou** `is_super_or_admin()` **ou**
  system. Normaliza placa (`upper`); idempotente via `on conflict (plate) do nothing`
  → `already_exists`. Valida driver existe, `capacity_kg > 0`.
- **`set_current_vehicle(p_vehicle_id)`** → `(ok, reason)`. Authz: driver dono do
  veículo (`vehicles.driver_id` → `drivers.user_id=auth.uid()`) ou admin. Seta
  `drivers.current_vehicle_id`.
- **`update_driver_status(p_driver_id, p_new_status)`** → `(ok, reason)`. Authz:
  `is_super_or_admin()` **apenas** (sem system — mutação de identidade, alinha a 0019).
  `p_new_status ∈ ('active','suspended','blocked')` (não permite voltar a `pending`).
  **Fecha o lado driver do risco offboarding** (ativo/suspender/bloquear).
- **`create_delivery_request(p_organization_id, p_business_id, p_business_location_id,
  p_pickup_*, p_delivery_*, p_vehicle_required, p_priority, p_scheduled_at, p_origin,
  p_external_reference, p_notes, p_instructions, p_items jsonb, p_correlation_id)`**
  → `table(ok boolean, reason text, delivery_request_id uuid)`. `set search_path =
  public, extensions, pg_catalog`. **Cria a corrida em `draft`** (sem preço — pricing
  é Sessão 07). Authz: system (null) **ou** `is_platform_admin()` **ou** membro da org.
  Valida tenancy (org existe; business na org; location no business); campos
  obrigatórios; **pré-valida itens** (jsonb array não-vazio, cada item com
  `description` não-vazio + `quantity > 0`). Monta `pickup_point`/`delivery_point`
  server-side (PostGIS). `external_reference` = dedup: `on conflict (organization_id,
  external_reference) do nothing` → `already_exists` (idempotente). Insere
  `delivery_items` (1:N) + `delivery_events` (`delivery_created`, `from_status=null`,
  `to_status='draft'`, ator capturado por `auth.uid()`). Tudo atômico.

**Matriz de autoridade (D4, estende ADR-009):** ver `docs/SECURITY.md` (seção
"Matriz de autoridade de gestão") e ADR-011. **Defesa em profundidade:** criação de
corrida é imposta no banco (RPC DEFINER valida tenancy) **e** no serviço (authz antes
da RPC) — igual ao padrão de atribuição.

### 4.3 RPC de pricing (Sessão 07, ADR-012)

Implementada em `supabase/migrations/0022_pricing_engine.sql` (1 RPC + ALTERs em
`pricing_rules`/`delivery_quotes`). **Nenhuma tabela nova.** **Modelo B**:
`SECURITY DEFINER` + `set search_path = public, pg_catalog`.

- **`create_quote(p_delivery_request_id, p_distance_meters integer,
  p_duration_seconds integer, p_correlation_id uuid default gen_random_uuid())`**
  → `table(ok boolean, reason text, quote_id uuid)`. **Primeiro RPC system-only**
  (ADR-012 D1): `auth.uid() IS NOT NULL` → `(false,'not_authorized',null)`. Grants:
  `revoke all from public` + `grant execute to service_role` **somente** —
  `authenticated` **não recebe EXECUTE** (defesa em profundidade; `anon`: nada).
  **Trust boundary:** os insumos de pricing (distância/duração) vêm do backend (provider
  de rota na Sessão 20), nunca do business — o dashboard "solicitar cotação" chama um
  Route Handler do backend, que chama `create_quote` system-scoped (Sessão 18).
- **Validações**: delivery existe e `status='draft'` (senão `wrong_state`);
  `vehicle_required` not null; `p_distance_meters > 0` (`invalid_distance`);
  `p_duration_seconds > 0` (`invalid_duration`).
- **Seleção de regra** (D4): org-specific (`organization_id` + `vehicle_type` + ativa +
  `effective_from ≤ now()`, mais recente) → fallback global (`organization_id is null`)
  → `no_pricing_rule`.
- **Cálculo** (D2): `base`, `distance_component = (per_km_cents × meters + 999)/1000`
  (ceil inteiro, sem float), `vehicle_component=0`, `urgency_component` (se `urgent`),
  `dynamic_component=0`; `subtotal = greatest(raw, min_price_cents)`; `customer_price =
  subtotal + platform_fee`; `driver_offer = subtotal − platform_fee` (`<0` →
  `pricing_error`). Faixa min/max (D3) via `min_multiplier`/`max_multiplier` (floor/ceil
  → bigint).
- **Atomicidade** (D5): chama `transition_delivery(p_id,'quoted','system',null,
  metadata{quote_id, preços, pricing_rule_id}, p_correlation_id)` **antes** do insert —
  se `not ok`, retorna **sem** insertar (sem quote órfã). Se ok, inserta `delivery_quotes`
  (`status='pending'`, `expires_at=now()+900s`, snapshot completo). Externamente atômico:
  ninguém observa `quoted` sem quote (mesma transação).
- **Ator** (D6): system path → evento `quote_created` com `actor_type='system'`
  (`auth.uid()` null); ator deriva de `auth.uid()`, nunca de param.

**Sem novos grants de DML a `authenticated`**; `authenticated` mantém SELECT sob RLS
(0017) em `delivery_quotes`/`pricing_rules` (vê a quote da sua org via
`can_view_delivery_request` e regras da sua org/global). Único grant novo: `execute on
create_quote to service_role`. `quoted_at`/`quote_created` são setados por
`transition_delivery` (0016, já na matriz).

### 4.4 RPCs de dispatch (Sessão 08, ADR-013)

Implementadas em `supabase/migrations/0023_dispatch_engine.sql` (2 RPCs). **Nenhuma
tabela/coluna nova** — tudo já existe em 0005/0009/0010. Modelo B: `SECURITY DEFINER`;
`authenticated` **sem DML** em `dispatch_rounds`/`delivery_offers` — só EXECUTE em
`confirm_quote` + SELECT sob RLS (0017); `anon`: nada.

- **`confirm_quote(p_delivery_request_id, p_correlation_id default gen_random_uuid())`**
  → `table(ok boolean, reason text)`. `SECURITY DEFINER`, `set search_path = public,
  pg_catalog`. **User-scoped** (D1): system (null) **ou** `is_platform_admin()` **ou**
  membro da org da corrida (`organization_memberships` join `delivery_requests`). Valida:
  delivery existe e `status='quoted'`; `delivery_quotes` `status='pending'` não expirada
  (a mais recente, `for update`) → `no_pending_quote`/`quote_expired`. **Transition-first**
  (D6): chama `transition_delivery(id,'searching_driver', ator, metadata{quote_id},
  p_correlation_id)` — `select for update` checa `quoted`, transita, seta
  `dispatch_started_at`, emite `dispatch_started`; se `not ok` (race → `wrong_state`),
  retorna **sem** marcar confirmed (sem órfã). Se ok, `update delivery_quotes set
  status='confirmed', confirmed_at=now()` + emite `delivery_events` `quote_confirmed`.
  Idempotência por estado: re-confirmar → `wrong_state`. Grants: `service_role` +
  `authenticated` (user-facing); `anon`: nada. Ator (D7): system=`'system'`,
  admin=`'admin'`, membro=`'business'`.
- **`open_dispatch_round(p_delivery_request_id, p_search_radius_m integer,
  p_max_candidates integer, p_driver_offer_cents bigint, p_response_window_seconds
  integer, p_max_location_age_seconds integer default 300, p_correlation_id uuid default
  gen_random_uuid())`** → `table(ok boolean, reason text, round_id uuid,
  candidate_count integer)`. `SECURITY DEFINER`, `set search_path = public, extensions,
  pg_catalog` (PostGIS). **System-only** (D2, segundo após `create_quote`):
  `auth.uid() IS NOT NULL` → `(false,'not_authorized',null,0)`. Grants: `service_role`
  **somente** (`authenticated` sem EXECUTE — defesa em profundidade); `anon`: nada. Trust
  boundary: insumos de dispatch (raio/candidatos/oferta/janela) vêm do backend, não do
  business. Valida: `status='searching_driver'` (senão `wrong_state`); params > 0 (senão
  `invalid_param`); sem rodada aberta (senão `round_already_open`). Cria `dispatch_round`
  (round_number monotônico, `config_snapshot`, `expires_at=now()+window`) + busca
  candidatos (D3 eligibility: `active`+`available`+veículo compatível+sem assignment
  ativa+localização fresca+`ST_DWithin` no raio; ordenação `ST_Distance` ASC, `LIMIT
  max_candidates`) e cria `delivery_offers` (uma por candidato, `status='pending'`,
  `driver_offer_cents`, `expires_at=round.expires_at`; UK `(round,driver)` protege dupla).
  Emite `round_opened` + `offer_created` por offer (ator `'system'`). **Cria a rodada
  mesmo com 0 candidatos** (audit snapshot; orquestrador expande o raio). Tudo atômico
  (rollback em falha de constraint — sem rodada órfã). Raio progressivo (D5) = orquestrador
  chama N vezes; fechar rodada/scoring/`claim_delivery` é **Sessão 09-10**.

**Sem novos grants de DML a `authenticated`; sem tabela nova** (D8): `dispatch_rounds`/
`delivery_offers` já têm RLS SELECT (0017, via `can_view_delivery_request`) +
`service_role` DML (0015). Único grant system-only novo: `execute on open_dispatch_round
to service_role`. `dispatch_started_at`/`dispatch_started` são setados por
`transition_delivery` (0016, já na matriz). Busca por PostGIS (`ST_DWithin`/`ST_Distance`)
é **filtro de candidatos** (proximidade operacional) — distinto de pricing, onde haversine
é proibido para cobrança.

### 4.5 RPC de bid engine (Sessão 09, ADR-014)

Implementada em `supabase/migrations/0024_bid_engine.sql` (1 RPC). **Nenhuma
tabela/coluna nova** — tudo já existe em 0005/0009/0010/0016. Modelo B: `SECURITY
DEFINER`; `authenticated` **sem EXECUTE** (defesa em profundidade); `anon`: nada.

- **`select_winner_and_claim(p_dispatch_round_id uuid, p_weight_price numeric default
  1.0, p_weight_distance numeric default 1.0, p_max_location_age_seconds integer default
  300, p_correlation_id uuid default gen_random_uuid())`** → `table(ok boolean, reason
  text, winner_driver_id uuid, winner_offer_id uuid, winner_bid_id uuid)`.
  `SECURITY DEFINER`, `set search_path = public, extensions, pg_catalog` (PostGIS
  `ST_Distance`/`ST_DWithin`). **System-only** (D1, terceiro após `create_quote`/
  `open_dispatch_round`): `auth.uid() IS NOT NULL` → `(false,'not_authorized',null,null,
  null)`. Grants: `revoke all from public` + `grant execute to service_role` **somente**
  (`authenticated` sem EXECUTE; `anon`: nada). **Trust boundary:** pesos de scoring vêm do
  backend (config do orquestrador), não do business — um business passando pesos forjaria
  o vencedor.
- **Validações**: params (D2) — `p_weight_price >= 0`, `p_weight_distance >= 0`, **não
  ambos 0**, `p_max_location_age_seconds > 0` (senão `invalid_param`); rodada existe e
  `status='open'` (senão `round_not_open`/`not_found`, `FOR UPDATE`); delivery
  `status='searching_driver'` (senão `wrong_state`, `FOR UPDATE`).
- **Candidatos válidos** (D3): offers respondidas (`accepted`/`counter_bid`) + join `bids`
  (`bid_amount_cents`) + re-valida eligibility do `open_dispatch_round` (active+available
  +veículo compatível+sem assignment ativa+localização fresca+`ST_DWithin` no raio da
  própria rodada) + offer não expirada. Declined excluída.
- **Scoring** (D4, min-max por window function): `norm_bid = (bid-min_bid)/nullif(max_bid-
  min_bid,0)`, `norm_dist` análogo; `score = p_weight_price*(1-norm_bid) +
  p_weight_distance*(1-norm_dist)` (`numeric` adimensional, maior = melhor). **Tie-break**:
  `score desc, dist_m asc, responded_at asc, driver_id asc`.
- **Sem vencedor** (0): fecha rodada manualmente + expira offers pending + emite
  `round_closed` (reason=`no_candidates`) + retorna `(true,'no_candidates',null,null,
  null)`. Delivery permanece `searching_driver`; rodada `closed` libera o guard
  `round_already_open` → orquestrador abre a próxima (raio maior).
- **Com vencedor**: emite `winner_selected` (scores de todos os candidatos no `metadata`
  — auditoria/explicabilidade) + chama `claim_delivery(v_delivery_id, v_winner_driver,
  p_dispatch_round_id, v_winner_offer, v_winner_bid, p_correlation_id)` (atomic; alias
  `as t` + `t.won, t.reason` — lição da Sessão 07). Claim `ok` → `(true,'won',...)`.
  Claim `not ok` por race (`already_assigned`/`not_searching_driver`/
  `delivery_not_found`) → fecha nossa rodada como superseded + `round_closed`
  (reason=`superseded_by_concurrent_claim`) + `(false, reason, null,null,null)`.
- **Ator** (D7): system → `actor_type='system'`, `actor_id=null` (system-only). Nunca de
  param. `winner_selected`/`round_closed` emitidos com ator system; `driver_assigned`
  emitido por `claim_delivery` (seu próprio ator system).
- **Sem `winner_*` em `dispatch_rounds`** (D6): vencedor recuperável por
  `delivery_assignments` (active) + `delivery_offers.status='won'` + `delivery_events`.

**Sem novos grants de DML a `authenticated`; sem tabela/coluna nova** (D8): único grant
novo = `execute on select_winner_and_claim to service_role`. `dispatch_rounds`/
`delivery_offers`/`bids` já têm RLS SELECT (0017) + `service_role` DML (0015).
`claim_delivery`/`transition_delivery` já concedidos a `service_role` (0016). **GATE
(Sessão 10)**: atomicidade funcional testada (exatamente 1 assignment ativo,
`already_assigned` no pós-race); harness de concorrência real é o gate formal de produção.

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
  para furar RLS. RPCs user-facing são `SECURITY DEFINER` com checagem interna de
  `auth.uid()` (Modelo B, Sessão 04; ver `ARCHITECTURE.md` §3.1).
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