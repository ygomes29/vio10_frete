# CODE_REVIEW.md — Log de revisão do ViO10

> Registro contínuo de revisões, security review e decisões de qualidade.
> Sessões 22 e 28 populam este arquivo em profundidade. Por enquanto, apenas a
> fundação.

## Histórico

### Sessão 11 — Ciclo completo (máquina de estados pós-`assigned` + POD gate, ADR-016) — PASS

- **ADR-016** escrito **antes** do código (matriz ator×transição D1, limite de reatribuição
  via metadata D2, cancelled/failed reason D3, POD two-phase D4, POD gate D5, completude
  D6, ator/eventos D7, sem tabela nova D8, split de migrations D9) — regra mestra respeitada.
  "IA não inventa status" garantido: toda transição por `transition_delivery` (refinada,
  assinatura inalterada); `delivered` é system-only via `confirm_delivery` (POD gate). O
  driver não auto-certifica entrega — "Submeter POD ≠ entregue" (análogo a ACEITAR ≠
  GANHAR, ADR-006).
- **0025** — schema prep (sem funções): `alter type delivery_event_type add value
  'pod_submitted'` + `unique (delivery_request_id, pod_type)` em `proof_of_delivery`. Sem
  função que referencie o novo valor — evita o gotcha `ALTER TYPE ... ADD VALUE` in-tx.
- **0026** — 3 RPCs `SECURITY DEFINER`:
  - `transition_delivery` **refinada** (assinatura inalterada): resolve classe de papel
    (system/admin/driver/business) de `auth.uid()`; matriz estrutural M primeiro
    (`invalid_transition`), depois matriz de papel R (`not_authorized`); limite de
    reatribuição (`p_metadata->>'max_reassignments'` — sem mutar se excedido); POD gate em
    `delivered` (`pod_required` sem POD delivery); `cancelled_reason`/`failed_reason` do
    metadata; `draft→cancelled` adicionado a M; supersede + `reassignment_count++`
    (existente). Grants inalterados (service_role + authenticated).
  - `submit_proof_of_delivery` (driver-scoped ou system; `search_path = public, extensions,
    pg_catalog`): valida completude (delivery: storage/otp + receiver_name; pickup:
    storage/otp/notes) + estado (delivery exige `in_transit`; pickup exige
    `driver_to_pickup`/`at_pickup`/`picked_up`/`in_transit`); insere POD (`unique_violation`
    → `pod_already_submitted`); emite `pod_submitted`; **não transita**. lat/lng double
    precision → geography server-side (padrão 0021). Grants: service_role + authenticated.
  - `confirm_delivery` (**system-only**, `search_path = public, pg_catalog`):
    `auth.uid() not null` → `not_authorized`; valida POD delivery existe (`pod_required`);
    chama `transition_delivery('delivered')` (alias `as t` + `t.ok, t.reason` — lição
    Sessão 07) que **re-valida** o POD gate (defense in depth). Grants: `service_role`
    **somente** (authenticated sem EXECUTE — defesa em profundidade). **Nenhuma
    tabela/coluna nova.**
- **`test_vio10_lifecycle.sql`** (65 asserções, begin/rollback + SELECT consolidado): T1-T22
  (happy path driver, pulo de estado, driver não entrega/reatribui/cancela/falha, business
  cancela pré-atribuição, admin pós-atribuição, system-only guard, limite de reatribuição,
  supersede, submit POD driver/não-autorizado/inválido/duplicado/wrong_state, confirm
  system/sem POD/system-only/wrong_state, POD gate direto, pickup POD, cancel/fail reason,
  draft→cancelled). Geometria isolada por longitude (cada teste pickup em B=N.0). **65/65
  PASS (real)**.
- **Callers internos preservados**: `create_quote` (system→draft→quoted ✓), `confirm_quote`
  (business/admin→quoted→searching_driver ✓). `claim_delivery`/`select_winner_and_claim` não
  chamam `transition_delivery` — GATE da Sessão 10 permanece íntegro (validado: bid 61/61,
  dispatch 65/65, sem regressão).
- **Bug de teste encontrado e corrigido na validação** (não bug de RPC): leak residual de
  JWT — `set_config('request.jwt.claims',...,true)` é is_local e persiste até o fim da
  **transação**, não do bloco. A 1ª versão setava JWT=driver em T1 sem resetar → T2's
  `mk_searching` rodava com `auth.uid()` = driver residual → `create_delivery_request`
  `not_authorized` → id null → `mk_assigned` null → `null value in column "dr_id"`. Corrigido:
  cada bloco reseta JWT para `'{}'` (system) antes dos helpers mk_*/create_*/confirm_quote,
  seta o ator antes das chamadas autenticadas, reseta para `'{}'` antes de chamadas
  system-only. **Lição Sessão 06 reconfirmada:** cada bloco autenticado deve resetar o JWT
  explicitamente; herdar JWT de bloco anterior mascara falhas de authz (e aqui, falha de
  setup). Diagnóstico exigiu captura do reason via temp table (RAISE NOTICE não alcança o
  resultset do endpoint — lição Sessão 03.5). 65/65 na 2ª execução.
- **`test_vio10_rpcs.sql` TR8 ajustado**: o POD gate novo (0026) faz `in_transit→delivered`
  exigir POD; inserção de POD adicionada antes da transição no teste. 48/48 após.
- **Reset/replay from-scratch**: `drop schema public cascade` + `delete from auth.users` +
  recriar `public` (via SQL + Management API) + replay **0001→0026 em ordem** → 26/26
  limpo. Inventário: 26 tabelas (nenhuma nova), RLS 26/26, POD unique `(delivery_request_id,
  pod_type)`, enum `pod_submitted`, 3 RPCs DEFINER (`confirm_delivery` system-only — execute
  só service_role, authenticated sem EXECUTE), `anon`=0 em `public`.
- **Suítes re-executadas após reset from-scratch**: invariants **13/13**, rpcs **48/48**,
  authz **21/21**, auth_lifecycle **34/34**, creation **37/37**, pricing **62/62**, dispatch
  **65/65**, bid **61/61**, lifecycle **65/65** — **9/9 suítes, 406 asserções, todas PASS
  (não simulado)**.
- **Risco aberto (BAIXO) — inalterado**: offboarding/revogação de papel/membership
  (`remove_platform_role`, `remove_org_member`) ainda deferido (lado driver FECHADO desde
  Sessão 06). Lock-ordering `claim_delivery`↔SWAC (Sessão 10 D4) — dívida técnica observada,
  não-hazard vivo, hardening adiado. Nenhum novo risco aberto na Sessão 11.
- **Veredito**: GO para Sessão 12 (POD completo: foto em Storage, OTP ao recebedor via
  WhatsApp, geolocation, verificação do recebedor, gating de pickup POD, auto-confirm
  orquestrado).

### Sessão 10 — Atribuição atômica em concorrência real (GATE de produção, ADR-007) — PASS

- **GATE de produção formalmente validado em concorrência REAL** (não simulada). A
  garantia do ADR-007 — ≤1 `delivery_assignment` ativa por `delivery_request` — foi
  exercitada sob **backends concorrentes** (conexões separadas), não sob single-transaction.
  **ADR-015** escrito antes do código (metodologia do harness, races, invariante, achado
  de lock-ordering, critério de PASS, ambiente/segurança).
- **Mecanismo do harness — curls paralelos ao Management API** (não `dblink`):
  `dblink_connect_u` é **negado** no dev (role do Management API não é superuser); pôr a
  senha do banco na linha de comando é vazamento de segredo (bloqueado). **Verificado
  empiricamente**: N `curl` paralelos (bash `&`+`wait`) ao endpoint `/database/query` rodam
  em conexões backend separadas e executam concorrentemente (dois `pg_sleep(1.5)` paralelos
  ≈ 2s wall vs 5s serial). Concorrência genuína sem `dblink`/superuser/senha exposta.
- **3 races × 5 runs = 15 corridas reais**, todas com o invariante sustentado
  (`n_assign=1, n_won=1, n_lost=1, del_status='assigned', round_status='closed'`):
  - **Test A — 2 `claim_delivery` paralelos** (mesma delivery, offers diferentes): sempre
    1 `true|won` + 1 `false|not_searching_driver` (lock `FOR UPDATE` em `delivery_requests`
    serializa; vencedor não-determinístico, invariante determinístico). Primitivo de
    atribuição.
  - **Test B — 2 `select_winner_and_claim` paralelos** (mesmo round): sempre 1
    `true|won` + 1 `false|round_not_open` (lock `FOR UPDATE` na rodada serializa). Hazard
    real de produção (orquestrador duplica/rechama o close — retry/webhook/2 workers).
  - **Test C — `select_winner_and_claim` vs `claim_delivery` direto**: 1 vencedor + 1
    perdedor; veredito só por DB-state (RPC não-determinístico aqui — ver D4).
- **Achado D4 — lock-ordering inconsistente (deadlock latente, NÃO-hazard vivo, reproduzido
  empiricamente)**: `select_winner_and_claim` (0024) adquire lock **round → delivery**;
  `claim_delivery` (0016) adquire **delivery → (UPDATE round late, não pre-lockado)**. Um
  `claim_delivery` **direto** raceando um SWAC em transações separadas sobre a mesma
  delivery forma ciclo de wait → Postgres detecta deadlock (40P01) e aborta um. **Run 2 do
  GATE reproduziu o 40P01** no side SWAC do Test C — e o invariante **sobreviveu**
  (`n_assign=1`). Empiricamente confirma a análise. **Não é hazard vivo**: `claim_delivery`
  é chamado **apenas dentro de** SWAC (mesma transação, re-lock reentrante, sem deadlock) —
  a transição `searching_driver → assigned` só via SWAC→claim (Sessão 09). `claim_delivery`
  tem `execute` a `service_role`, então o backend *poderia* chamá-lo direto, mas o caminho
  arquitetado é SWAC-only. **Hardening adiado** (dívida técnica observada — não muda o
  invariante): se um futuro camino chamar `claim_delivery` direto concorrente com SWAC
  (reatribuição de emergência, integração legada), endurecer o lock order (claim adquirir
  round `FOR UPDATE` antes do delivery, espelhando SWAC) ou centralizar o close fora do
  claim. Adiado para não desestabilizar o código validado da Sessão 09.
- **Bug de harness encontrado e corrigido na validação** (não bug de RPC): a 1ª versão
  reusava as mesmas longitudes (100/200/300) entre os 5 runs → drivers **perdedores** de
  runs anteriores (active/available, sem assignment, localização fresca) vazavam para a
  eligibility do `open_dispatch_round` de runs posteriores → offers pending extras → R16
  marcava-as `lost` → `n_lost` crescia (1,2,3,4,4). O invariante **núcleo** (`n_assign=1`,
  `n_won=1`) **nunca violado** — só `n_lost` (cosmético do harness). Corrigido com offset
  de 1°/run (~111km >> raio 10km) → isolamento total. **Lição:** poluição cross-RUN, mesma
  classe da poluição cross-scenario da Sessão 09 — isole por pickup geográfica distinta
  (não só por cenário, por **run** também) quando drivers perdedores persistem
  active/available sem assignment entre runs.
- **Sem migration, sem schema/RPC/grant novo**. `claim_delivery` (0016) e
  `select_winner_and_claim` (0024) intactos — Sessão 10 é validação, não feature. Harness
  commitado em `supabase/tests/concurrency_harness.sh` + `concurrency_setup.sql` para
  reprodutibilidade/auditoria do GATE.
- **Reset/replay + regressão**: reset via SQL + replay **0001→0024** (24/24 limpo);
  inventário 26 tabelas, RLS 26/26, `select_winner_and_claim` DEFINER system-only
  (execute só service_role), `anon`=0 em `public`. **8 suítes re-executadas**: invariants
  **13/13**, rpcs **48/48**, authz **21/21**, auth_lifecycle **34/34**, creation **37/37**,
  pricing **62/62**, dispatch **65/65**, bid **61/61** — todas PASS (não simulado).
- **Risco aberto (BAIXO) — novo**: lock-ordering `claim_delivery`↔SWAC (D4 acima) —
  dívida técnica observada, não-hazard vivo (claim só roda dentro de SWAC). Hardening
  adiado. Offboarding/revogação de papel/membership permanece deferido (Sessão 06).
- **Veredito**: **GATE PASS** → GO para Sessão 11 (ciclo completo: máquina de estados +
  proof of delivery).

### Sessão 09 — Bid engine (scoring + seleção + `claim_delivery` atômico) — PASS

- **ADR-014** escrito **antes** do código (1 RPC system-only D1, fluxo D2, candidatos
  válidos D3, scoring min-max D4, seleção≠confirmação D5, auditoria sem coluna de winner
  D6, ator via `auth.uid` D7, sem novos grants/sem tabela nova D8) — regra mestra
  respeitada. "IA não inventa entregador": o vencedor vem do scoring determinístico no
  banco (min-max de `bid_amount_cents` + `ST_Distance`), não de IA; toda transição por
  `transition_delivery` (via `claim_delivery`). "ACEITAR ≠ GANHAR" (ADR-006) garantido: a
  seleção considera só quem ainda é válido no close e o claim é atômico.
- **0024 — `select_winner_and_claim`** `SECURITY DEFINER` **system-only** (terceiro
  system-only após `create_quote`/`open_dispatch_round`): `auth.uid() not null` →
  `not_authorized`. Grants: `revoke public` + `execute` só a `service_role` —
  `authenticated` **nem EXECUTE** (defesa em profundidade); `anon`: nada. **Trust
  boundary correto:** pesos de scoring vêm do backend, não do business — um business
  passando pesos forjaria o vencedor. Scoring `numeric` adimensional (não dinheiro;
  `bid_amount_cents` permanece `bigint`). **Tie-break determinístico** `score desc,
  dist_m asc, responded_at asc, driver_id asc`. `nullif` evita divisão por zero. Chama
  `claim_delivery` com alias `as t` + `t.won, t.reason` (lição da Sessão 07 aplicada
  proativamente). Re-valida eligibility no close (driver que aceitou mas foi atribuído a
  outra corrida é excluído; offer → `lost`/`expired`). Sem vencedor → fecha rodada +
  `no_candidates` (orquestrador abre a próxima de raio maior). Com vencedor →
  `winner_selected` (scores no metadata) + `claim_delivery` (atribui, fecha, R16,
  `driver_assigned`). Claim race → superseded + retorna o reason. **Nenhuma
  tabela/coluna nova** — vencedor em `delivery_assignments`(active) +
  `delivery_offers.status='won'` + `delivery_events`.
- **`test_vio10_bid.sql`** (61 asserções, begin/rollback + SELECT consolidado): T1-T16
  (basic win, no_candidates, counter_bid, weight_price=0, weight sensitivity,
  eligibility re-check assignment-race/offline/expired, round_already_closed, wrong_state,
  system-only, invalid_param, tie-break, fator constante/nullif, raio progressivo,
  not_found). Geometria isolada por cenário (cada teste pickup em longitude distinta,
  drivers em B+off; bases ~111km aparte → sem poluição cross-scenario). **61/61 PASS
  (real)**.
- **Bug de teste encontrado e corrigido na validação** (não bug de RPC): a 1ª versão
  compartilhava pickup `(0,0)` entre todos os cenários → drivers de testes anteriores
  vazavam para `open_dispatch_round` de testes posteriores (single-tx `begin/rollback`),
  e com `max_candidates=10` polluters mais próximos crowding-out os drivers-alvo (T5a/T5b
  vencedor errado, T15 count=10 em vez de 1/2). Corrigido com longitude de pickup distinta
  por cenário. Mais uma asserção invertida (`T2_no_winner` expected `'f'`→`'t'`).
  **Lição de teste single-tx:** cada cenário que cria drivers ativos/available/fresh num
  mesmo `begin;…rollback;` polui a eligibility de cenários posteriores se compartilham a
  pickup — isole por pickup geográfico distinto (drivers do teste em B+off; bases >> raio).
- **Proativamente sem bugs de RPC em runtime**: a lição da Sessão 07 (ambiguidade `as t`
  ao chamar `returns table(...)` de dentro de outra `returns table(...)`) foi aplicada em
  0024 ao chamar `claim_delivery`; a lição da Sessão 08 (PostGIS `st_*` não-qualificado,
  vive em `extensions`) também. Replay 24/24 "limpo" não garante runtime — a suíte bid
  confirmou (61/61 na 2ª execução; as 5 falhas da 1ª eram bugs de teste, não de RPC).
- **Reset/replay from-scratch**: `drop schema public cascade` + `delete from auth.users`
  + recriar `public` (via SQL + Management API) + replay **0001→0024 em ordem** → 24/24
  limpo. Inventário: 26 tabelas (nenhuma nova), RLS 26/26, `select_winner_and_claim`
  DEFINER system-only (execute só service_role, authenticated sem EXECUTE), `anon`=0 em
  `public`.
- **Suítes re-executadas após reset from-scratch**: invariants **13/13**, rpcs **48/48**,
  authz **21/21**, auth_lifecycle **34/34**, creation **37/37**, pricing **62/62**, dispatch
  **65/65**, bid **61/61** — todas PASS (não simulado).
- **Risco aberto (BAIXO) — inalterado**: offboarding/revogação de papel/membership
  (`remove_platform_role`, `remove_org_member`) ainda deferido (lado driver FECHADO desde
  Sessão 06). Nenhum novo risco aberto na Sessão 09.
- **Veredito**: GO para Sessão 10 (atribuição atômica em **concorrência real** — GATE de
  produção; harness via `dblink`/paralelismo, greenfield, ADR-007).

### Sessão 08 — Dispatch engine (busca de candidatos + raio progressivo) — PASS

- **ADR-013** escrito **antes** do código (2 RPCs/2 trust boundaries D1/D2, eligibility MVP
  D3, criação atômica D4, raio progressivo orquestrado D5, atomicidade/guards D6, ator via
  `auth.uid` D7, sem novos grants/sem tabela nova D8) — regra mestra respeitada. "IA não
  inventa entregador ou status": candidatos vêm da query de eligibility do banco, não de IA;
  toda transição por `transition_delivery`.
- **0023 — 2 RPCs `SECURITY DEFINER`**:
  - `confirm_quote` (user-scoped, `search_path = public, pg_catalog`): authz system/
    `is_platform_admin()`/membro da org; valida `quoted` + quote `pending` não expirada;
    **transition-first** (alias `as t` + `t.ok, t.reason` — lição da Sessão 07 aplicada
    proativamente, sem ambiguidade 42702); se falhar, retorna sem marcar (sem órfã);
    confirma quote + emite `quote_confirmed`. Grants: `service_role`+`authenticated`
    (user-facing); `anon`: nada.
  - `open_dispatch_round` (system-only, segundo após `create_quote`,
    `search_path = public, extensions, pg_catalog`): `auth.uid() not null` →
    `not_authorized`; grants só a `service_role` (`authenticated` sem EXECUTE — defesa em
    profundidade). Cria `dispatch_round` + `delivery_offers` por candidato elegível
    atomicamente; `round_already_open` guard; `round_number` monotônico; cria rodada mesmo
    com 0 candidatos (audit). PostGIS `st_dwithin`/`st_distance` **não-qualificados**
    (vivem em `extensions`, não `public` — armadilha evitada proativamente).
- **`test_vio10_dispatch.sql`** (65 asserções, begin/rollback + SELECT consolidado):
  `confirm_quote` (membro org; authz wrong-org/system/re-confirm/wrong_state/expired);
  `open_dispatch_round` (rodada 1 raio 2000 → 2 candidatos; system-only; eligibility
  radius 500; max_candidates; round_already_open; raio progressivo round 2; wrong_state;
  0 candidatos; invalid_param). Geometria no equador (distâncias determinísticas).
  **65/65 PASS (real)**.
- **Proativamente sem bugs de validação**: a lição da Sessão 07 (ambiguidade PL/pgSQL
  `as t`) foi aplicada em `confirm_quote` antes do replay; a lição do PostGIS em
  `extensions` (não `public`) foi aplicada em `open_dispatch_round` antes do replay. O
  replay 23/23 "limpo" não garante runtime — mas as suítes confirmam runtime. **Nenhum bug
  encontrado na validação** (primeira sessão sem correção em runtime desde a 03.5).
- **Reset/replay from-scratch**: `drop schema public cascade` + `delete from auth.users`
  + recriar `public` (via SQL + Management API) + replay **0001→0023 em ordem** → 23/23
  limpo. Inventário: 26 tabelas (nenhuma nova), RLS 26/26, `confirm_quote` DEFINER (execute
  service_role+authenticated), `open_dispatch_round` DEFINER system-only (execute só
  service_role, authenticated sem EXECUTE), `anon`=0 em `public`.
- **Suítes re-executadas após reset from-scratch**: invariants **13/13**, rpcs **48/48**,
  authz **21/21**, auth_lifecycle **34/34**, creation **37/37**, pricing **62/62**, dispatch
  **65/65** — todas PASS (não simulado). Nota: pgTAP `finish()` neste dev emite via RAISE
  (0 rows no resultset); `num_failed()=0` é a autoridade + último resultset confirma nº de
  testes.
- **Risco aberto (BAIXO) — inalterado**: offboarding/revogação de papel/membership
  (`remove_platform_role`, `remove_org_member`) ainda deferido (lado driver FECHADO desde
  Sessão 06). Nenhum novo risco aberto na Sessão 08.
- **Veredito**: GO para Sessão 09 (bid engine + atribuição atômica — GATE).

### Sessão 07 — Pricing engine determinístico (cotação, `draft → quoted`) — PASS

- **ADR-012** escrito **antes** do código (system-only, álgebra D2, faixa min/max D3,
  seleção de regra org→global D4, atomicidade transition-first D5, ator via `auth.uid`
  D6, TTL/estado D7/D8) — regra mestra respeitada. "IA não inventa preço" garantido: o
  valor cobrado/devido vem do motor determinístico, não de IA.
- **0022 — `create_quote`** `SECURITY DEFINER` **system-only** (primeiro RPC system-only):
  `auth.uid() IS NOT NULL` → `not_authorized`. Grants: `revoke public` + `execute` só a
  `service_role` — `authenticated` **nem EXECUTE** (defesa em profundidade antes da
  checagem interna); `anon`: nada. **Trust boundary correto:** insumos de rota
  (distância/duração) vêm do backend (provider Sessão 20), não do business. Álgebra em
  `bigint` cents, `distance_component` por divisão inteira com ceil (sem float no
  dinheiro). `vehicle_component`/`dynamic_component` = 0 (explícito no snapshot). Faixa
  min/max via multipliers (`numeric` floor/ceil → bigint). Atomicidade: chama
  `transition_delivery('quoted')` **antes** do insert — se falhar, retorna sem insertar
  (sem quote órfã). Nenhuma tabela nova; colunas herdam RLS de 0012/0017.
- **`test_vio10_pricing.sql`** (62 asserções, begin/rollback + SELECT consolidado):
  componentes/álgebra/faixa/snapshot/status/evento; urgent; carro vs moto; `min_price`
  floor; faixa não-degenerada; `pricing_error`; `no_pricing_rule`; fallback global;
  `wrong_state`; `invalid_distance`/`invalid_duration`; authz (autenticado negado /
  system ok); `distance_component` ceil. **62/62 PASS (real)**.
- **Bug real encontrado e corrigido na validação**: `select ok, reason from
  transition_delivery(...)` dentro de `create_quote` era **ambíguo** (ERRO 42702) — em
  PL/pgSQL, as colunas de saída de `returns table(ok, reason, quote_id)` viram variáveis
  implícitas no corpo, conflitando com as colunas do retorno de `transition_delivery`.
  Corrigido aliasando: `from transition_delivery(...) as t` + `t.ok, t.reason`.
  **Lição:** `create or replace function` **não executa o corpo** ao aplicar a migration
  — replay 22/22 "limpo" não garante que a função funciona; o bug só apareceu em
  runtime (suíte de pricing). Replay não substitui exercitar a RPC.
- **Reset/replay from-scratch**: `drop schema public cascade` + `delete from auth.users`
  + recriar `public` (via SQL + Management API) + replay **0001→0022 em ordem** → 22/22
  limpo. Inventário: 26 tabelas (nenhuma nova), RLS 26/26, `create_quote` DEFINER,
  `authenticated` sem EXECUTE em `create_quote`, `service_role` com EXECUTE, `anon`=0 em
  `public`.
- **Suítes re-executadas após reset from-scratch**: invariants **13/13**, rpcs **48/48**,
  authz **21/21**, auth_lifecycle **34/34**, creation **37/37**, pricing **62/62** —
  todas PASS (não simulado).
- **Risco aberto (BAIXO) — inalterado**: offboarding/revogação de papel/membership
  (`remove_platform_role`, `remove_org_member`) ainda deferido (lado driver FECHADO
  desde a Sessão 06). Nenhum novo risco aberto na Sessão 07.
- **Veredito**: GO para Sessão 08 (dispatch: busca de candidatos + raio progressivo).

### Sessão 06 — Criação da corrida + gestão de empresas/veículos/entregadores — PASS

- **ADR-011** escrito **antes** do código (criação=draft sem preço, snapshots,
  external_reference=dedup, matriz de autoridade de gestão D4, mutação só via RPC
  DEFINER, capture de ator) — regra mestra respeitada.
- **0020 — 6 RPCs `SECURITY DEFINER`** (`create_organization`, `create_business`,
  `create_business_location`, `create_vehicle`, `set_current_vehicle`,
  `update_driver_status`) + `create unique index idx_vehicles_plate_uk on
  vehicles(plate)`. Authz por `auth.uid()`; `create_vehicle` driver self (driver-owned);
  `update_driver_status` super/admin **sem system** (mutação de identidade, alinha a
  0019). Idempotentes onde há chave natural (`create_vehicle` via `on conflict (plate)`
  → `already_exists`). Grants: authenticated EXECUTE (sem DML); anon nada.
- **0021 — `create_delivery_request`** `SECURITY DEFINER`: cria `draft` + itens +
  evento `delivery_created` numa transação. Authz system/admin/membro de org. Pontos
  PostGIS montados server-side (`set search_path = public, extensions, pg_catalog`).
  `external_reference` dedup via `on conflict (organization_id, external_reference)
  do nothing` → `already_exists`. Pré-valida itens (jsonb array, description não-vazio,
  quantity > 0). Capture de ator por `auth.uid()` (D6 — nunca de param).
- **`test_vio10_creation.sql`** (37 asserções, begin/rollback + SELECT consolidado):
  org/business/location/vehicle/set_current_vehicle/update_driver_status/
  create_delivery_request; cross-tenant negado; admin/operator/system ok;
  external_reference dedup; location de outro business; itens vazios/malformados;
  vehicle_required null; pickup_lat null; ponto xy; evento delivery_created.
  **37/37 PASS (real)**.
- **Bug real encontrado e corrigido na validação**: bloco T4 (`create_vehicle` driver
  self) não executava `set_config` antes — rodava sob JWT residual `uBO`
  (business_owner) → `not_authorized` (downstream: T4b e T5 falhavam). Adicionado
  `set_config(uDrv)` antes do bloco; T4b ajustado para mesmo driver + placa duplicada
  (antes usava `v_drv2`, que falhava authz antes do conflito de placa). **Lição: cada
  bloco de teste autenticado deve setar explicitamente o JWT; herdar JWT de bloco
  anterior mascara falhas de authz.**
- **Reset/replay from-scratch**: `drop schema public cascade` + `delete from
  auth.users` + recriar `public` (via SQL + Management API) + replay **0001→0021 em
  ordem** → 21/21 limpo. Inventário: 26 tabelas (nenhuma nova), RLS 26/26, 7 novos
  RPCs DEFINER, `vehicles.plate` unique, `anon`=0 em `public`.
- **Suítes re-executadas após reset from-scratch**: invariants **13/13**, rpcs
  **48/48**, authz **21/21**, auth_lifecycle **34/34**, creation **37/37** — todas
  PASS (não simulado).
- **Risco aberto (BAIXO) atualizado — offboarding/revogação**: lado **driver**
  **FECHADO** nesta sessão (`update_driver_status`: active/suspended/blocked). Lado
  **papel/membership** (`remove_platform_role`, `remove_org_member`) **ainda
  deferido** (Sessão 06+ quando surgir o fluxo de offboarding completo). Ver "Achados
  abertos".
- **Veredito**: GO para Sessão 07 (pricing engine determinístico; `draft → quoted`).

### Sessão 05 — Auth de usuários (Supabase Auth) + reset/replay from-scratch — PASS

- **ADR-010** escrito **antes** do código (auth method, profile, convites, JWT,
  session, matriz de quem convida quem) — regra mestra respeitada.
- **0018 `handle_new_user`** (`SECURITY DEFINER` on `auth.users` AFTER INSERT →
  `profiles`, `on conflict do nothing`): garante FK de `user_platform_roles`/
  `organization_memberships`/`drivers` → `profiles(id)`. O trigger **não** atribui
  papel (ato explícito via 0019). Sobrevive a `drop schema public cascade` (vive no
  schema `auth`); 0018 o recria idempotente no replay.
- **0019 `invitations` + 6 RPCs `SECURITY DEFINER`** (`create_invitation`,
  `accept_invitation`, `cancel_invitation`, `assign_platform_role`,
  `add_org_member`, `create_driver`) + helpers `my_email()`, `is_super_or_admin()`.
  Idempotentes (`on conflict do nothing`); authz por `auth.uid()`. Grants
  least-privilege (authenticated: EXECUTE + SELECT em `invitations` sob RLS, sem
  DML direto; anon: nada).
- **Bug real de escalonamento de privilégio encontrado e corrigido na validação**:
  os 4 RPCs de **mutação** usavam `is_platform_admin()` (que inclui `operator`,
  helper de *visibilidade* do ADR-009) → um `operator` podia atribuir papel a
  terceiros, criar driver, cancelar convite alheio. Corrigido: mutação usa
  `is_super_or_admin()` (`super_admin`/`admin`, exclui `operator`). RLS de
  *visibilidade* de `invitations` mantém `is_platform_admin()` (operator vê —
  leitura, ADR-009). Formalizado em ADR-010 D4.1. **Lição: V (visibilidade) ≠
  C/X (autoridade de agir); um helper de RLS não deve ser reusado como helper de
  authz de mutação sem confirmar a quem ele inclui.**
- **`test_vio10_auth_lifecycle.sql`** (34 asserções, begin/rollback): trigger,
  convites, authz do inviter, idempotência de accept, prova de email, expiração,
  driver via convite, RLS de invitations, anon bloqueado. **34/34 PASS (real)**.
- **`test_vio10_invariants.sql`**: `plan(12)`→`plan(13)` (rodava 13 asserções).
- **Reset/replay from-scratch (hardening final)**: `drop schema public cascade` +
  `delete from auth.users` + recriar `public` (via SQL + Management API; **não há**
  endpoint de reset a nível de projeto — só branch) + replay **0001→0019 em ordem**
  → todos aplicam limpo (19/19, sem MIGFAIL). Inventário: 26 tabelas (incl.
  `invitations`), RLS em todas (26/26), trigger `handle_new_user` presente,
  `anon`=0 grants.
- **Suítes re-executadas após reset from-scratch**: invariants **13/13**, rpcs
  **48/48**, authz **21/21**, auth_lifecycle **34/34** — todas PASS (não simulado).
- ~~**Risco em aberto (BAIXO): reset/replay from-scratch da cadeia 0001→0017 não
  executado**~~ → **FECHADO nesta sessão** (reset via SQL + replay 0001→0019
  limpo). Risco original da Sessão 04 resolvido.
- **Risco aberto (BAIXO)**: revogação de papel (`remove_platform_role`,
  `remove_org_member`, `deactivate_driver`) e limpeza assíncrona de convites
  expirados não existem — adiados (Sessão 06+ offboarding; ADR-010 "Fora do
  escopo"). `accept_invitation` rejeita `expires_at < now()`; limpeza é otimização.
- **Veredito**: GO para Sessão 06 (criação da corrida: empresas/entregadores/
  veículos + `delivery_request`).

### Sessão 04 — Auth/Grants/RLS/RBAC (Modelo B) — PASS

- **ADR-009** matriz RBAC escrita **antes** do código (grants/policies derivados da
  spec, não inventados — regra mestra respeitada). Driver corrigido: não está em
  `user_platform_roles` (identificado por linha em `drivers`).
- **Modelo B (decisão de usuário)**: RPCs user-facing `SECURITY DEFINER` + checagem
  interna de `auth.uid()`. **Reverte** INVOKER da Sessão 03. Descoberto na Sessão 04:
  INVOKER exigiria DML a `authenticated`, abrindo bypass da máquina de estados via
  PostgREST direto (`PATCH delivery_requests.status`). DEFINER + sem DML de domínio ao
  `authenticated` fecha o buraco. `auth.uid()` funciona sob DEFINER (lê JWT).
- **0016** aplicada (real): 4 RPCs confirmadas `SECURITY DEFINER`; grants PUBLIC
  revogados; EXECUTE reaplicado conforme 0015.
- **0017** aplicada (real): 25 policies + 5 helpers DEFINER (`is_platform_admin`,
  `my_driver_id`, `my_org_ids`, `is_org_member`, `can_view_delivery_request`).
- **`test_vio10_authz.sql` executado (real)**: **21/21 PASS** — cross-tenant (userA
  vê 0 de orgB, userB 0 de orgA), isolamento de driver (driverD só reqA/own offer/own
  row; driverD2 só reqB), papel sem policy vê 0 (userN), admin vê tudo (2/2/2), bypass
  UPDATE bloqueado (`insufficient_privilege`), `respond_to_offer` bloqueia driver
  errado (`not_authorized`) e permite o dono (`responded`).
- **System-path (auth.uid null) preservado**: smoke `claim_delivery` 4/4; R16
  cross-round PASS; **concorrência 2 claims paralelas → exatamente 1 `won=true`**
  (B won, A `not_searching_driver`), nunca ambos — partial unique index + `FOR UPDATE`
  intactos sob DEFINER.
- **Inventário final (real)**: 26 tabelas com RLS, 25 policies, 4 RPCs DEFINER, 5
  helpers, `authenticated` SELECT=20/INSERT=1/UPDATE=1/EXECUTE=8, `anon`=0.
- **Risco aberto (BAIXO)**: bypass via PostgREST **FECHADO** (Modelo B + grants sem
  DML de domínio ao authenticated). Invariante imutabilidade `delivery_events` confirmado
  novamente (bloqueou DELETE de cleanup, mesmo para owner).
- ~~**Risco em aberto (BAIXO)**: reset/replay from-scratch da cadeia 0001→0017 não
  executado~~ → **FECHADO na Sessão 05** (reset via SQL + Management API + replay
  0001→0019 limpo; ver Sessão 05).
- **Veredito**: GO para Sessão 05 (Auth de usuários Supabase + reset/replay from-scratch).

### Sessão 03.5 — Validação real da fundação (Gate B) — PASS
- **pgTAP executado (real)**: 12/12 invariantes PASS. Resolve o risco ALTO da Sessão 03
  (testes não executados). Executado server-side via Management API (sem Docker):
  runner próprio com temp table `_tap` + `num_failed()` + `begin/rollback` clean-slate.
- **RPCs executadas**: 48/48 PASS (4 RPCs × cenários de happy path, expiração,
  idempotência, transições inválidas, FK, reatribuição).
- **Concorrência `claim_delivery`**: 2 claims simultâneas → exatamente 1 `won=true`,
  nunca A=true E B=true. Garantia física (partial unique index) + lógica (`FOR UPDATE`).
- **`delivery_events` imutável**: trigger bloqueia UPDATE/DELETE (T12 PASS).
- **RLS default deny**: role autorizada sem policy vê 0 linhas (T10 PASS).
- **Grants audit (real)**: descoberto e corrigido gap — `revoke … from public` não
  removia auto-grants do Supabase a `anon`/`authenticated`/`service_role`. 0014
  endurecido: revoga de todos + `ALTER DEFAULT PRIVILEGES … REVOKE`. Após: 0
  privilégios para os três roles em 25 tabelas + 10 funções; owner retém.
- **R16 resolvido**: após atribuição oficial, TODAS as offers respondíveis da corrida
  (em qualquer rodada) viram `lost` — `claim_delivery` filtra por `delivery_request_id`.
  Teste cross-round real PASS. Resolve o risco MÉDIO da Sessão 03.
- **R17 documentado**: `external_reference` ≠ `idempotency_key`. Resolve o risco
  BAIXO da Sessão 03.
- **Correção arquitetural**: `service_role` user-scoped vs system-scoped (ver
  `ARCHITECTURE.md` §3.1).
- **PostGIS search_path**: migrations 0004/0005/0006/0007/0011 + test files recebem
  `set search_path to public, extensions;` (runner não inclui `extensions`).
- **Cadeia reproduzível**: reset + 0001→0014 do zero — 25 tabelas, 16 enums, 7 funcs,
  25 RLS, 14 migrations.
- **Veredito**: GO para Sessão 04 (Auth/Grants/RLS/RBAC).

### Sessão 03 — Banco (Gate B) — implementação
- Invariante crítica (atribuição única) protegida no banco: partial unique index +
  RPC `claim_delivery` com `FOR UPDATE`. Conforme ADR-007.
- RPCs em `SECURITY INVOKER` + `search_path` fixo; **nenhum** `SECURITY DEFINER` para
  bypassar RLS (regra respeitada).
- RLS default deny desde a primeira migration (sem policies amplas) — Sessão 04 formaliza.
- `delivery_events` imutável por trigger.
- ~~**Risco aberto (ALTO)**: testes pgTAP não executados~~ → **RESOLVIDO na Sessão 03.5**.
- ~~**Risco (MÉDIO)**: offers de rounds anteriores~~ → **RESOLVIDO (R16) na Sessão 03.5**.
- ~~**Risco (BAIXO)**: `external_reference` unique com NULLs~~ → **documentado (R17) na
  Sessão 03.5**; comportamento SQL intencional, idempotência via `integration_events`.

### Sessão 01 — Diagnóstico
- Repositório greenfield confirmado. Nenhuma stack herdada.
- Risco crítico identificado: atribuição dupla de corrida → mitigado por
  constraint + RPC transacional (formalizado na Sessão 02 / ADR-007).
- Risco crítico: n8n como fonte da verdade → mitigado por fronteiras de escrita
  (ADR-004).

### Sessão 02 — Documentação
- Decisões arquiteturais formalizadas em ADRs (ADR-001 a ADR-008).
- Correção crítica aplicada: semântica de ACEITAR no bid engine (não é vitória
  imediata). Registrada em ADR-006 e `docs/BID_ENGINE.md`.

## Achados abertos

- **Revogação de papel / offboarding** (BAIXO): lado **driver** **FECHADO** na Sessão
  06 (`update_driver_status`: active/suspended/blocked). Lado **papel/membership**
  (`remove_platform_role`, `remove_org_member`) e limpeza assíncrona de convites
  expirados ainda não existem (Sessão 05 entregou atribuição, não revogação). Adiados
  para Sessão 06+ (fluxo de offboarding completo). `accept_invitation` já rejeita
  `expires_at < now()`; o modelo (`drivers.account_status`, delete em memberships)
  suporta revogação futura.

## Classificação de severidade (a usar nas revisões)

- **P0** — bloqueia produção
- **P1** — risco alto
- **P2** — importante
- **P3** — melhoria

## Tópicos a cobrir na Sessão 22 (security review)

Autenticação, autorização, RLS, APIs, server actions, webhooks, uploads, storage,
links de aceitação, secrets, env vars, DataCrazy, n8n, banco, logs, PII, endpoints
administrativos, rate limiting, abuso, replay, IDOR, injection, concorrência.

## Notas de segurança conhecidas já registradas

- **Next.js 16.3.3** patch de segurança (25/ago/2026): corrige RCE em otimização de
  imagens AVIF (GHSA-2xp9-vwfh-vxw4) e RCE em Windows (GHSA-p293-qw3h-jr36). O RCE de
  Windows não nos atinge (deploy em Linux/Vercel). AVIF é desabilitado na patch.
  Fonte: [August 2026 Security Release](https://nextjs.org/blog/august-2026-security-release).