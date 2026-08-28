# ADR-013 — Dispatch engine (busca de candidatos + raio progressivo, `quoted → searching_driver`)

- **Status**: Aprovado
- **Data**: 2026-08-28
- **Sessão**: 08

## Contexto

A Sessão 07 entrega a corrida em `quoted` com cotação (`delivery_quotes.status='pending'`,
`expires_at`, `confirmed_at` ainda null). A Sessão 08 é a Fase 4 do roadmap ("Dispatch"):
implementa o **motor de despacho** em dois movimentos:

1. **Confirmação da cotação** — business/operator confirma a quote pendente →
   `quoted → searching_driver` (via `transition_delivery`, que já tem essa transição na
   matriz, emite `dispatch_started` e seta `dispatch_started_at`), e marca a quote
   `confirmed` + `confirmed_at`.
2. **Abertura de rodadas de dispatch** — o backend/orquestrador abre `dispatch_rounds`
   com um raio, busca candidatos por PostGIS (`ST_DWithin` em `driver_locations.position`
   vs `pickup_point`) e cria `delivery_offers` para cada candidato elegível.

Tudo o que o motor precisa já existe no schema: `drivers`/`vehicles`/`driver_locations`
(0005), `delivery_requests.pickup_point`/`dispatch_started_at` (0007), `dispatch_rounds`/
`delivery_offers`/`bids` (0009), `delivery_assignments` (0010, partial unique index ativa),
`transition_delivery`/`claim_delivery`/`respond_to_offer` (0013/0016), RLS SELECT em
dispatch/quote (0017), `service_role` DML (0015). **Nenhuma RPC de dispatch existia** — a
Sessão 08 cria as duas que faltam: `confirm_quote` e `open_dispatch_round`. **Nenhuma
tabela/coluna nova.**

`docs/DISPATCH_ENGINE.md` estabelece o ciclo (raio progressivo, eligibility, rodada), e
`docs/DELIVERY_LIFECYCLE.md` diz que `quoted → searching_driver` é disparado por
business/operator (confirma) e `searching_driver → assigned` por `claim_delivery`
(Sessão 09-10). A regra mestra vale: nenhuma camada altera `status` direto — toda
transição por `transition_delivery`. A busca por proximidade usa PostGIS — permitido
para **filtro de candidatos** (distinto de pricing, onde haversine é proibido para
cobrança; aqui é proximidade operacional, não cobrança).

### Decisões de usuário (confirmadas no planejamento da Sessão 08)
- **2 RPCs, 2 trust boundaries**: `confirm_quote` (user-scoped, membro da org/operator)
  confirma a cotação; `open_dispatch_round` (system-only, como `create_quote`) abre cada
  rodada. Componível: o orquestrador chama `open_dispatch_round` N vezes (raio
  progressivo). Alinha a "Backend decide, n8n orquestra".
- **Parâmetros do caller (backend)**: `open_dispatch_round` recebe raio/max_candidates/
  driver_offer/janela como params do backend (que lê config própria). Espelha
  `create_quote` (insumos do backend, system-only). **Sem tabela de config nova** no MVP
  (`dispatch_config` adiada).
- **Filtro de área operacional (service_areas) por entregador ADIADO no MVP**: candidatos
  filtrados só por raio até a coleta (`ST_DWithin`) + veículo compatível + available + ativo
  + sem assignment ativa + localização fresca. `service_areas` (sem junction
  driver↔area hoje) fica como pré-condição futura.

## Decisões

### D1 — `confirm_quote` é user-scoped (membro da org / operator / admin / system)

`confirm_quote(p_delivery_request_id uuid, p_correlation_id uuid default gen_random_uuid())`
→ `table(ok boolean, reason text)`. `SECURITY DEFINER`, `search_path = public, pg_catalog`.

Authz (igual `create_delivery_request`, ADR-011 D4): `auth.uid()` null (system) **ou**
`is_platform_admin()` **ou** membro da org da corrida (`organization_memberships`).
Rejeita membro de outra org → `not_authorized`.

Valida: delivery existe e `status='quoted'`; existe `delivery_quotes` com `status='pending'`
e `expires_at > now()` (a mais recente) → senão `no_pending_quote` / `quote_expired`.

Atomicamente (transition-first, igual `create_quote` ADR-012 D5):
1. Chama `transition_delivery(id, 'quoted'→'searching_driver', ator,
   metadata{quote_id}, p_correlation_id)` — `select for update` checa `status='quoted'`,
   transita, seta `dispatch_started_at`, emite `dispatch_started`.
2. Se `not ok` → retorna **sem** marcar confirmed (sem quote confirmed órfã; ex.:
   `wrong_state` se status mudou concorrentemente).
3. Se `ok` → `update delivery_quotes set status='confirmed', confirmed_at=now()` (a quote
   pendente que validou) + emite `delivery_events` `quote_confirmed` (ator via `auth.uid`).

Idempotência por estado: re-confirmar (status já `searching_driver`) → `wrong_state`.
Sem `idempotency_key`/`external_reference` (idempotência por estado, ADR-012 D8).

Ator (D6 ADR-011): system→`'system'`, platform admin→`'admin'`, membro de org→`'business'`;
`actor_id=auth.uid()` quando presente. Ator nunca de param.

**Grants**: `revoke all from public`; `execute` a `service_role` **e** `authenticated`
(user-facing, como `create_delivery_request`). `anon`: nada.

### D2 — `open_dispatch_round` é system-only (segundo RPC system-only, após `create_quote`)

`open_dispatch_round(p_delivery_request_id uuid, p_search_radius_m integer,
p_max_candidates integer, p_driver_offer_cents bigint, p_response_window_seconds integer,
p_max_location_age_seconds integer default 300, p_correlation_id uuid default
gen_random_uuid())` → `table(ok boolean, reason text, round_id uuid, candidate_count integer)`.
`SECURITY DEFINER`, `search_path = public, extensions, pg_catalog` (usa PostGIS
`ST_DWithin`/`ST_Distance`).

Authz: `auth.uid() IS NOT NULL` → `(false, 'not_authorized', null, 0)`.

**Trust boundary:** raio/candidatos/oferta são insumos do orquestrador (backend), não do
business. Se um business autenticado passasse `p_search_radius_m`/`p_driver_offer_cents`,
poderia manipular a busca/oferta. System-only garante que os insumos vêm do backend (que
lê config própria; `dispatch_config` table adiada). Espelha `create_quote` (primeiro
system-only, ADR-012 D1).

**Grants**: `revoke all from public`; `execute` só a `service_role` — `authenticated`
**nem EXECUTE** (defesa em profundidade, bloqueio no nível de privilégio antes da checagem
interna de `auth.uid()`). `anon`: nada.

### D3 — Eligibility dos candidatos (MVP)

Um driver é candidato sse **todos**:
- `drivers.account_status = 'active'`;
- `drivers.current_availability_status = 'available'`;
- `drivers.current_vehicle_id is not null` e `vehicles.vehicle_type =
  delivery.vehicle_required` (join pelo veículo corrente);
- **sem assignment ativa**: `not exists (select 1 from delivery_assignments a where
  a.driver_id = drivers.id and a.status = 'active')`;
- tem localização fresca: `driver_locations.position is not null and captured_at >
  now() - p_max_location_age_seconds`;
- dentro do raio: `ST_DWithin(driver_locations.position, dr.pickup_point,
  p_search_radius_m)` (geography, metros).

Ordenação: `ST_Distance(driver_locations.position, dr.pickup_point) ASC`, `LIMIT
p_max_candidates`. O índice GiST em `driver_locations.position` (0005) suporta a busca
espacial; o filtro de `vehicle_type`/assignment/frescor reduz o conjunto antes do
`LIMIT`.

**Filtro `service_areas` por entregador ADIADO** (raio até a coleta é a restrição espacial
no MVP). **Capacidade/peso/dims no dispatch ADIADO** (só vehicle_type no MVP;
`weight_g`/dims ficam no scoring futuro). **Não muta `drivers.current_availability_status`**
ao criar offers: o valor `offered` do enum é **reservado**, não usado no MVP — o driver
permanece `available` e pode receber offers de rodadas distintas; o guard contra dupla
offer do mesmo driver na mesma rodada é o UK `(dispatch_round_id, driver_id)` de
`delivery_offers`.

### D4 — Criação atômica de rodada + offers

`open_dispatch_round` numa transação `SECURITY DEFINER`:
1. Valida delivery existe e `status='searching_driver'` (senão `wrong_state`); valida
   `p_search_radius_m > 0`, `p_max_candidates > 0`, `p_driver_offer_cents >= 0`,
   `p_response_window_seconds > 0` (senão `invalid_param`).
2. Guarda de rodada aberta: se existe `dispatch_rounds` com `delivery_request_id` e
   `status='open'` → `(false, 'round_already_open', null, 0)`. Fechar/superseder a rodada
   anterior é **Sessão 09** (scoring/seleção/`claim_delivery`); o orquestrador não abre a
   próxima enquanto há rodada aberta.
3. `v_round_number := coalesce(max(round_number), 0) + 1`; `v_expires := now() +
   p_response_window_seconds`.
4. INSERT `dispatch_rounds` (round_number, search_radius_m, max_candidates,
   driver_offer_cents, config_snapshot=`{radius, max_candidates, offer, window,
   max_location_age}`, expires_at, status='open').
5. Query candidatos (D3) → `v_candidates`.
6. Para cada candidato: INSERT `delivery_offers` (delivery_request_id, dispatch_round_id,
   driver_id, driver_offer_cents=`p_driver_offer_cents`, status='pending',
   expires_at=`v_expires`). UK `(dispatch_round_id, driver_id)` protege dupla.
7. Emite `delivery_events`: `round_opened` (metadata {round_id, round_number, radius,
   candidate_count}) + `offer_created` por offer (metadata {round_id, driver_id, offer_id,
   expires_at}). Ator `'system'`.
8. Retorna `(true, 'opened', v_round_id, v_candidate_count)`. Se 0 candidatos: **cria a
   rodada** (audit: snapshot da tentativa no raio) e retorna `candidate_count=0` — o
   orquestrador sabe expandir o raio (próxima rodada).

Se qualquer offer insert falhar (constraint), rollback (sem rodada órfã). A rodada + todas
as offers são atômicas (mesmo commit).

### D5 — Raio progressivo é orquestrado (não no RPC)

O DB RPC abre **uma rodada** por chamada com os params dados. A sequência crescente de
raios (rodada 1→menor, 2→médio, 3→maior) e o limite de rodadas/raio máximo são decididos
pelo **orquestrador** (backend/n8n, Sessões 13-14). `round_number` é monotônico por corrida
(snapshot de cada tentativa). Kill switches (limite de rodadas, raio máximo, dispatcher
off) → Sessão 26 (fora de escopo). A composicionalidade (chamar N vezes) é o motivo de
`open_dispatch_round` ser system-only e stateless quanto à sequência.

### D6 — Atomicidade e guards de estado

`confirm_quote`: transition-first (lock `for update`, `quoted → searching_driver`), depois
confirma a quote; se a transição falhar, rollback (sem quote confirmed órfã).
`open_dispatch_round`: tudo numa tx; se qualquer offer insert falhar (constraint),
rollback (sem rodada órfã). Sem `idempotency_key`/`external_reference` em ambos
(idempotência por estado, ADR-012 D8); retries de API/integration ficam com
`integration_events.idempotency_key` (Sessão 13).

### D7 — Ator via `auth.uid()` (D6 ADR-011/012)

`confirm_quote`: system→`'system'`, platform admin→`'admin'`, membro de org→`'business'`;
`actor_id=auth.uid()` quando presente. `open_dispatch_round`: sempre `'system'`
(system-only). Ator nunca de param.

### D8 — Sem novos grants de DML a `authenticated`; sem tabela nova

`dispatch_rounds`/`delivery_offers` já têm RLS SELECT (0017, via
`can_view_delivery_request`) + `service_role` DML (0015). `authenticated` mantém SELECT
sob RLS (vê rounds/offers da sua org/driver) + EXECUTE em `confirm_quote` (user-facing).
Único grant system-only novo: `execute on open_dispatch_round to service_role`. `anon`:
nada. **Nenhuma tabela/coluna nova** — tudo já existe em 0005/0009/0010.

## Consequências

- **0023** cria `confirm_quote` (user-scoped DEFINER) e `open_dispatch_round` (system-only
  DEFINER) + grants. **Nenhuma tabela/coluna nova.**
- Sem novos grants de DML a `authenticated`; `authenticated` mantém SELECT sob RLS +
  EXECUTE em `confirm_quote`. `open_dispatch_round`: só `service_role`.
- **Defesa em profundidade**: dispatch é imposto no banco (RPCs DEFINER validam estado +
  eligibility; offers criadas atomicamente). O business não toca nos insumos de dispatch
  (raio/oferta). `claim_delivery` (0013) continua sendo o único caminho para
  `searching_driver → assigned` (Sessão 09-10).
- **`quoted → searching_driver` só via `confirm_quote`**: embora `transition_delivery`
  aceite essa transição para system/admin/org-member, o caminho legítimo de confirmação é
  `confirm_quote` (que valida a quote pendente e marca `confirmed_at`). Chamar
  `transition_delivery('searching_driver')` direto criaria `searching_driver` sem quote
  confirmada — não é bloqueado no banco no MVP (deferido: guard de que
  `searching_driver` implica quote confirmed), mas é contrato da camada de serviço usar
  `confirm_quote`.
- **Raio progressivo** = orquestrador chama `open_dispatch_round` repetidamente com raios
  crescentes, fechando cada rodada (Sessão 09) antes de abrir a próxima. O RPC é puro (uma
  rodada por chamada); `round_number` rastreia a sequência.

## Fora do escopo (adiado)

- **Bid engine (scoring + seleção + `claim_delivery`)** → **Sessão 09-10** (GATE). Fechar
  rodada, coletar respostas, pontuar, escolher vencedor, `claim_delivery` atômico. A
  Sessão 08 só **abre** rodadas + cria offers; `respond_to_offer` (0013) já registra
  respostas; `claim_delivery` (0013) já atribui.
- **`dispatch_config` table** (raio/round por org) → adiado; MVP usa params do backend.
- **Filtro `service_areas` por entregador** (position dentro de service_area ativa) →
  adiado; MVP usa só raio até a coleta.
- **`offered` state ao criar offer** (mutar `current_availability_status`) → adiado
  (reservado no enum); driver permanece `available`.
- **Capacidade/peso/dims no dispatch** → MVP: só vehicle_type; capacity/eligibility de
  peso fica no scoring futuro.
- **Kill switches** (limite de rodadas, raio máximo, dispatcher off) → Sessão 26.
- **Provider de rota real** (Google Maps) → Sessão 20; dispatch usa PostGIS proximity.
- **Rate limiting** → camada de serviço/API (Sessão 22).
- **Guard de `quoted` implica quote / `searching_driver` implica quote confirmed** →
  Sessão 11-12 (máquina de estados).

## Referências

`ADR-009` (RBAC, Modelo B), `ADR-011` (criação=`draft`, authz org/admin/system),
`ADR-012` (system-only pattern, transition-first, idempotência por estado),
`docs/DISPATCH_ENGINE.md` (ciclo, eligibility, raio progressivo),
`docs/DELIVERY_LIFECYCLE.md` (`quoted → searching_driver` = confirma;
`searching_driver → assigned` = `claim_delivery`),
`docs/SECURITY.md` (system-only, trust boundaries, defesa em profundidade),
`0005_drivers.sql` (`drivers`, `vehicles`, `driver_locations` GiST),
`0007_delivery_core.sql` (`pickup_point`, `dispatch_started_at`),
`0009_dispatch_bids.sql` (`dispatch_rounds`, `delivery_offers` UK),
`0010_assignments_events.sql` (partial unique index ativa, `delivery_events` imutável),
`0016_rpcs_security_definer.sql` (`transition_delivery` matriz + `dispatch_started` +
`dispatch_started_at`; `claim_delivery`), `0017_rls_policies.sql` (RLS SELECT dispatch/quote),
`0002_enums.sql` (`dispatch_round_status`, `delivery_offer_status`,
`driver_availability_status`, `delivery_event_type`).