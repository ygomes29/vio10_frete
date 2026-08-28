# ADR-014 — Bid engine (scoring + seleção + `claim_delivery` atômico, `searching_driver → assigned`)

- **Status**: Aprovado
- **Data**: 2026-08-28
- **Sessão**: 09

## Contexto

A Sessão 08 entrega a corrida em `searching_driver` com rodadas abertas
(`dispatch_rounds.status='open'`) + `delivery_offers` (`pending`) distribuídas aos
candidatos. Os drivers respondem via `respond_to_offer` (0016, já existe):
ACCEPT/COUNTER_BID/DECLINE, registrados em `bids`. **ACEITAR ≠ GANHAR** (ADR-006): aceitar
é um lance igual a `driver_offer_cents` (disposição de fazer a corrida pelo valor ofertado),
**não** uma vitória. A rodada coleta candidatos numa janela; ao fechar, pontua, escolhe o
vencedor e só então executa `claim_delivery` atomicamente.

A Sessão 09 é a Fase 5 do roadmap ("Lances"), **GATE**: a atribuição atômica em
concorrência real é validada formalmente na Sessão 10 (harness via `dblink`/paralelismo,
greenfield — ADR-007), mas a Sessão 09 já entrega o caminho completo de seleção → claim.
Implementa o que falta: **fechar a rodada → coletar candidatos válidos → pontuar
deterministicamente → escolher vencedor → `claim_delivery` atômico**.

Toda a infraestrutura atômica já existe: `claim_delivery` (0016, `SELECT … FOR UPDATE`
em `delivery_requests` + partial unique index `idx_delivery_assignments_active_uk` +
R16 cross-round + `already_assigned` em `unique_violation`), `transition_delivery` (0016,
matriz `searching_driver→assigned`, emite `driver_assigned`), enums `winner_selected`/
`round_closed` já em `delivery_event_type` (0002, hoje não-usados). **Nenhuma RPC de
scoring/close/seleção existe** (confirmado na exploração). **Nenhuma tabela/coluna nova** —
o vencedor já vive em `delivery_assignments` (linha `active`) + `delivery_offers.status=
'won'` + `delivery_events` metadata; sem `winner_*` em `dispatch_rounds`.

**Ponto crítico de design (descoberto na análise):** `claim_delivery` (0016) exige
`round_status='open'` e **ele mesmo fecha a rodada** após atribuir (linhas 117-119:
`set status='closed' where delivery_request_id=… and status='open'`) + marca R16 as
demais offers respondíveis `lost`. Logo o fluxo correto é: **com vencedor →
`claim_delivery` fecha a rodada; sem vencedor → fechamos manualmente**. A rodada `closed`
libera o guard `round_already_open` do `open_dispatch_round` (ADR-013 D4.2), permitindo a
próxima rodada de raio maior (raio progressivo).

`docs/BID_ENGINE.md` estabelece a semântica (ACEITAR≠GANHAR, scoring, close sequence,
invariáveis) e `docs/DELIVERY_LIFECYCLE.md` diz que `searching_driver → assigned` é via
`claim_delivery`. A regra mestra vale: nenhuma camada altera `status` direto — toda
transição por `transition_delivery` (o `claim_delivery` chama). IA não inventa
preço/ETA/entregador/status — o scoring é determinístico no DB, o vencedor vem do DB.
`service_role` nunca vaza para n8n/DataCrazy — eles chamam o backend, que chama a RPC
system-scoped. Dinheiro em inteiros (`*_cents` bigint); o *score* é adimensional
(`numeric`, ranking — não é dinheiro).

### Decisões de usuário (confirmadas no planejamento da Sessão 09)
- **1 RPC system-only `select_winner_and_claim`**: fecha a rodada, pontua candidatos
  válidos in-DB, escolhe vencedor determinístico, chama `claim_delivery` internamente
  (atômico). Sem vencedor → fecha a rodada + retorna `no_candidates` (orquestrador abre a
  próxima rodada de raio maior). Espelha o padrão system-only de `create_quote`/
  `open_dispatch_round` (ADR-012/013). `BACKEND.md` §4 já previa `select_winner_and_claim`.
- **Fatores de scoring MVP: `bid_amount_cents` + distância PostGIS (`ST_Distance`
  `driver_locations.position` vs `pickup_point`); ETA peso 0** até o RoutingProvider
  (Sessão 20). Distância como proxy operacional (mesma justificativa do `ST_DWithin` de
  dispatch — filtro/ordenação de proximidade, não cobrança). Sem float para dinheiro; o
  score adimensional é `numeric`.
- **Pesos como params do caller (backend), sem tabela de config**: como
  `open_dispatch_round` (insumos do backend, system-only). `scoring_config` table adiada.

## Decisões

### D1 — `select_winner_and_claim` é system-only (terceiro RPC system-only)

`select_winner_and_claim(p_dispatch_round_id uuid, p_weight_price numeric default 1.0,
p_weight_distance numeric default 1.0, p_max_location_age_seconds integer default 300,
p_correlation_id uuid default gen_random_uuid())`
→ `table(ok boolean, reason text, winner_driver_id uuid, winner_offer_id uuid,
winner_bid_id uuid)`. `SECURITY DEFINER`, `search_path = public, extensions, pg_catalog`
(usa PostGIS `ST_Distance`/`ST_DWithin`).

Authz: `auth.uid() IS NOT NULL` → `(false, 'not_authorized', null, null, null)`.

**Trust boundary:** os pesos de scoring vêm do backend (config do orquestrador), não do
business. Se um business autenticado passasse `p_weight_price`/`p_weight_distance`,
poderia manipular o vencedor. System-only garante que os insumos vêm do backend (que lê
config própria; `scoring_config` table adiada). Espelha `create_quote`/`open_dispatch_round`
(ADR-012 D1, ADR-013 D2).

**Grants**: `revoke all from public`; `execute` só a `service_role` — `authenticated`
**nem EXECUTE** (defesa em profundidade, bloqueio no nível de privilégio antes da checagem
interna de `auth.uid()`). `anon`: nada.

Idempotência por estado: chamar de novo em rodada já `closed` → `round_not_open` (não
re-claima, não duplica efeito).

### D2 — Fluxo: validate → coletar → (0: fechar manual) | (≥1: pontuar → claim)

`select_winner_and_claim` numa transação `SECURITY DEFINER`:

1. **Valida input**: `p_dispatch_round_id` existe e `status='open'` (senão
   `round_not_open`/`not_found`); `p_weight_price >= 0`, `p_weight_distance >= 0`, **e não
   ambos 0** (senão `invalid_param`); `p_max_location_age_seconds > 0` (senão
   `invalid_param`). Resolve `v_delivery_id` da rodada.
2. **Lock + valida estado**: `SELECT … FOR UPDATE` em `delivery_requests`; valida
   `status='searching_driver'` (senão `wrong_state` — já `assigned` por race de outra
   rodada, ou `cancelled`/etc). Lock `FOR UPDATE` na rodada também.
3. **Coleta candidatos válidos** (D3): offers desta rodada `status in
   ('accepted','counter_bid')`, join `bids` (`bid_amount_cents`), re-valida eligibility do
   driver + offer não expirada.
4. **Se 0 candidatos** (sem vencedor): (a) `update dispatch_rounds set status='closed',
   closed_at=now()`; (b) `update delivery_offers set status='expired' where status=
   'pending'` (offers não respondidas expiram); (c) emite `delivery_events` `round_closed`
   (metadata `{round_id, round_number, reason:'no_candidates', candidate_count:0}`);
   (d) retorna `(true, 'no_candidates', null, null, null)`. Delivery permanece
   `searching_driver`; a rodada `closed` libera o guard → orquestrador abre a próxima
   (raio maior).
5. **Se ≥1 candidato**: (a) **pontua** (D4); (b) escolhe vencedor (D5); (c) emite
   `winner_selected` (metadata: scores de todos os candidatos — auditoria, D6); (d) chama
   `claim_delivery(p_delivery_id, p_winner_driver_id, p_dispatch_round_id,
   p_winner_offer_id, p_winner_bid_id, p_correlation_id)` (atômico; valida round open,
   atribui, fecha a rodada, R16 perde demais offers, emite `driver_assigned`).
   (e) Se claim `ok` → retorna `(true, 'won', winner_driver_id, winner_offer_id,
   winner_bid_id)`. Se claim `not ok`: se reason ∈ (`already_assigned`,
   `not_searching_driver`) → race de outra rodada: fecha nossa rodada como superseded
   (`status='closed'`, metadata `reason:'superseded_by_concurrent_claim'`), emite
   `round_closed`, retorna `(false, claim_reason, null, null, null)`; demais reasons
   (`round_not_open`/`offer_expired` — não esperados após validar) → retorna
   `(false, claim_reason, …)`.

### D3 — Candidatos válidos = responded + ainda-eligible

Reusa a eligibility do `open_dispatch_round` (ADR-013 D3, 0023:201-217) verbatim, **mas** a
partir das offers **respondidas** (não pending): `delivery_offers` deste round `status in
('accepted','counter_bid')`, join `bids` (`bid_amount_cents`; UK `(delivery_offer_id,
driver_id)` — uma bid por offer/driver), join `drivers`/`vehicles`/`driver_locations`,
onde:
- `drivers.account_status='active'` (driver pode ter sido suspenso entre offer e close);
- `drivers.current_availability_status='available'` (driver pode ter ido offline/busy);
- `vehicles.vehicle_type = delivery.vehicle_required` (join por `current_vehicle_id`);
- **sem assignment ativa**: `not exists (select 1 from delivery_assignments a where
  a.driver_id = drivers.id and a.status='active')` (driver pode ter sido atribuído a outra
  corrida);
- localização fresca: `driver_locations.position is not null and captured_at >
  now() - p_max_location_age_seconds`;
- dentro do raio da **própria** rodada: `ST_DWithin(driver_locations.position,
  delivery.pickup_point, round.search_radius_m)`;
- offer não expirada: `delivery_offers.expires_at > now()`.

Declined offers excluídas (`status='declined'`). Pending já expiradas no passo 4/D2.

**Re-validação no close (essencial):** o driver que ACEITOU mas depois foi atribuído a
outra corrida (race) é excluído — sua offer, ao claimarmos outro vencedor, vira `lost`
(R16 do `claim_delivery`) ou `expired` (no path no_candidates). O driver que foi suspenso
ou foi offline também é excluído. Consistente com ADR-006: a seleção considera só quem
ainda é válido no momento do close.

### D4 — Scoring determinístico (normalização min-max, pesos de param)

Para o conjunto de candidatos válidos, calcule por candidato (window functions numa única
query):
- `bid_amount_cents` (bigint; menor = melhor): ACCEPT → `driver_offer_cents`; COUNTER_BID
  → `bids.bid_amount_cents`.
- `dist_m` = `ST_Distance(driver_locations.position, delivery.pickup_point)` (geography,
  metros; menor = melhor).

Normalize cada fator a [0,1] via min-max: `norm_bid = (bid - min_bid) /
nullif(max_bid - min_bid, 0)` (todos iguais → 0); `norm_dist` análogo. Lower-is-better →
goodness = `1 - norm`. `score = p_weight_price * (1 - norm_bid) + p_weight_distance *
(1 - norm_dist)` (`numeric`; maior = melhor). Se um peso = 0, o fator é ignorado; ambos 0
rejeitado em D1 (`invalid_param`).

**Tie-break determinístico** (não ditado por ADR-006; definido aqui): `order by score
desc, dist_m asc, o.responded_at asc, d.id asc`. Distância como primeiro desempate (proxy
operacional), depois rapidez de resposta (`delivery_offers.responded_at`), depois
`driver_id` (estável, determinístico entre runs).

`nullif` evita divisão por zero (fator constante → norm 0 para todos → goodness 1 → não
diferencia; o tie-break decide). O score é `numeric` (ranking adimensional) — **não é
dinheiro**; dinheiro permanece `bigint` em `bid_amount_cents`.

### D5 — Seleção = o melhor candidato; atribuição = `claim_delivery`

Bid Engine *escolhe* (D4), `claim_delivery` *confirma* (ADR-007). Mesmo após escolher, o
vencedor não é oficial até claim passar (partial unique index + `FOR UPDATE` garantem no
máximo 1 assignment ativo por corrida). Se claim falhar por race (`already_assigned`/
`not_searching_driver`), a rodada é fechada como superseded e o orquestrador é informado
(não há retry automático — decisão do orquestrador).

**Sem early-close arbitrária no MVP** (ADR-006): early close futuro só por regra
determinística explícita (ex.: `candidate_score >= fast_accept_threshold`), nunca
"primeiro que aceitar ganha". O MVP espera o timeout da janela — o orquestrador chama
`select_winner_and_claim` quando a janela fecha.

### D6 — Auditoria via `delivery_events` (sem coluna nova)

O score de todos os candidatos vai no `metadata` do evento `winner_selected` (jsonb array:
cada candidato com `{driver_id, offer_id, bid_id, bid_amount_cents, dist_m, score}`) —
rastro completo e **explicável** (requisito `BID_ENGINE.md`). `round_closed` (path
no_candidates / superseded) carrega `{round_id, round_number, reason, candidate_count}`.
`driver_assigned` (emitido por `claim_delivery`, 0016) carrega `{driver_id, offer_id,
round_id, bid_id}`.

**Sem `winner_*` em `dispatch_rounds`** — o vencedor é recuperável pela linha `active` de
`delivery_assignments` + `delivery_offers.status='won'` + `delivery_events`. Mantém
"nenhuma tabela/coluna nova" (consistente com ADR-012/013 D8).

### D7 — Ator via `auth.uid()` (system → 'system')

System-only → sempre `actor_type='system'`, `actor_id=null` (`auth.uid()` null no path
system). Ator nunca de param. `winner_selected`/`round_closed` emitidos com ator system;
`driver_assigned` é emitido por `claim_delivery` (com seu próprio ator system).

### D8 — Sem novos grants de DML a `authenticated`; sem tabela/coluna nova

`dispatch_rounds`/`delivery_offers`/`bids` já têm RLS SELECT (0017, via
`can_view_delivery_request`) + `service_role` DML (0015). `claim_delivery`/
`transition_delivery` já concedidos a `service_role` (0016). `authenticated` mantém SELECT
sob RLS (vê rounds/offers/bids da sua org/driver) + EXECUTE nas RPCs user-facing existentes;
**sem EXECUTE** em `select_winner_and_claim`. Único grant novo: `execute on
select_winner_and_claim to service_role` (somente). `anon`: nada. **Nenhuma
tabela/coluna nova** — tudo já existe em 0005/0009/0010/0016.

## Consequências

- **0024** cria `select_winner_and_claim` (system-only DEFINER) + grants. **Nenhuma
  tabela/coluna nova.**
- Sem novos grants de DML a `authenticated`; `authenticated` mantém SELECT sob RLS +
  EXECUTE nas RPCs user-facing existentes. `select_winner_and_claim`: só `service_role`.
- **Defesa em profundidade**: o scoring/seleção é imposto no banco (RPC DEFINER pontua
  deterministicamente, re-valida eligibility no close, chama `claim_delivery` atômico). O
  business não toca nos pesos de scoring. `claim_delivery` (0016) continua sendo o único
  caminho para `searching_driver → assigned`; a Sessão 09 só decide **quem** chamar.
- **`searching_driver → assigned` só via `select_winner_and_claim` → `claim_delivery`**:
  o caminho legítimo de fechar a rodada e atribuir é esta RPC. Chamar `claim_delivery`
  direto com um vencedor arbitrário não é bloqueado no banco no MVP (claim aceita qualquer
  offer accepted/counter_bid válida), mas é contrato da camada de serviço usar
  `select_winner_and_claim` (que pontua deterministicamente e audita os scores).
- **Raio progressivo** = orquestrador chama `open_dispatch_round` (raio maior) +
  `select_winner_and_claim` (fecha + tenta atribuir) repetidamente. Sem vencedor
  (`no_candidates`) → próxima rodada. Com vencedor → `assigned`, fim do dispatch.
- **GATE (Sessão 10)**: a atomicidade de `claim_delivery` já é testada funcionalmente
  (exatamente 1 assignment ativo, `already_assigned` no pós-race). O harness de
  **concorrência real** (dois `select_winner_and_claim`/`claim_delivery` paralelos via
  `dblink`/advisory lock) é o gate formal de produção (ADR-007) — Sessão 10.

## Fora do escopo (adiado)

- **Atribuição atômica em concorrência real (GATE de produção)** → **Sessão 10**.
  Sessão 09 valida claim atomicamente (funcional), mas o harness de concorrência real é o
  gate formal.
- **Early-close determinístico** (`candidate_score >= fast_accept_threshold`) → adiado;
  MVP espera o timeout da janela.
- **ETA no scoring** (via RoutingProvider) → Sessão 20; MVP usa distância como proxy.
- **`scoring_config` table** (pesos por org/veículo/urgência) → adiado; MVP usa params do
  backend.
- **`service_areas` por entregador no scoring** → adiado; reusa a eligibility de raio.
- **Capacidade/peso/dims no scoring** → MVP: só vehicle_type (eligibility); capacidade
  fica no scoring futuro.
- **Kill switches** (scoring off, reject-all-bids, veto) → Sessão 26.
- **Notificação de vencedor/perdedor ao driver** (DataCrazy/WhatsApp) → Sessão 15-16.
- **Rate limiting** → camada de serviço/API (Sessão 22).

## Referências

`ADR-006` (ACEITAR≠GANHAR, close sequence), `ADR-007` (atribuição atômica, partial unique
index, GATE de concorrência), `ADR-009` (RBAC, Modelo B), `ADR-012` (system-only pattern,
idempotência por estado), `ADR-013` (dispatch eligibility, raio progressivo, guard
`round_already_open`), `docs/BID_ENGINE.md` (semântica, scoring, invariáveis),
`docs/DELIVERY_LIFECYCLE.md` (`searching_driver → assigned` = `claim_delivery`),
`docs/SECURITY.md` (system-only, trust boundaries), `0005_drivers.sql` (`drivers`,
`vehicles`, `driver_locations`), `0009_dispatch_bids.sql` (`dispatch_rounds`,
`delivery_offers` UK, `bids`), `0010_assignments_events.sql` (partial unique index ativa,
`delivery_events` imutável), `0016_rpcs_security_definer.sql` (`claim_delivery`,
`respond_to_offer`, `transition_delivery` matriz), `0002_enums.sql`
(`delivery_event_type` `winner_selected`/`round_closed`, `delivery_offer_status`,
`dispatch_round_status`).