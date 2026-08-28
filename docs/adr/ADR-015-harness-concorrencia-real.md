# ADR-015 — Harness de concorrência real (GATE de produção, ADR-007)

- **Status**: Aprovado
- **Data**: 2026-08-28
- **Sessão**: 10

## Contexto

A Sessão 09 (ADR-014) entregou o caminho completo `searching_driver → assigned` via
`select_winner_and_claim` (system-only) → `claim_delivery` (0016, atômico). A atomicidade é
garantida por construção (ADR-007): partial unique index
`idx_delivery_assignments_active_uk` (`UNIQUE(delivery_request_id) WHERE status='active'`)
+ `SELECT … FOR UPDATE` em `delivery_requests`. A Sessão 09 validou isso
**funcionalmente** (exatamente 1 assignment active, `already_assigned`/`not_searching_driver`
no pós-race), mas em **single-transaction** (begin;…rollback;) — ou seja, **simulado**,
não concorrência real entre backends separados.

A **Sessão 10 é o GATE de produção** (ADR-007 consequências: "testes de concorrência são
gate de produção"). O que falta é provar o invariante sob **concorrência real** — duas ou
mais chamadas RPC disputando a **mesma** corrida em **conexões backend separadas**,
executando concorrentemente (não serializadas pelo cliente).

### Por que não `dblink`

A abordagem original (CLAUDE.md/PLAN.md: "harness via `dblink`/paralelismo") era disparar
`claim_delivery`/`select_winner_and_claim` em paralelo dentro de uma única conexão via
`dblink_connect`. **Verificado no dev: `dblink_connect_u` é NEGIED** (erro 42501 — o role
do Management API **não é superuser**; `dblink_connect_u` exige superuser para senhas
embutidas). `dblink_connect` (sem `_u`) exigiria a senha do role em texto na connection
string — colocar a senha do banco literalmente na linha de comando é **vazamento de
segredo** (bloqueado por classificação de segurança; nunca consultar `pg_authid.rolpassword`).

### Mecanismo aprovado: curls paralelos via Management API

**Verificado empiricamente no dev**: `N` chamadas `curl` paralelas (bash `&` + `wait`) ao
endpoint Management API `/database/query` rodam em **conexões backend separadas** e
executam **concorrentemente** — provado com dois `pg_sleep(1.5)` paralelos (wall ≈ 2s) vs
seriais (wall ≈ 5s). Logo, disparar `N` curls paralelos chamando a mesma RPC contra a mesma
corrida produz concorrência **genuína** no nível do Postgres, **sem** `dblink`, **sem**
superuser, **sem** senha exposta. É o mecanismo do harness.

## Decisão

### D1 — Harness via curls paralelos ao Management API (não `dblink`)

O harness é um script bash que, para cada race:
1. **Setup** (uma chamada SQL sequencial, **committed** — os curls paralelos rodam em
   conexões separadas e precisam ver os dados): cria org + pricing rule + 2 drivers
   (com veículo motorcycle + localização fresca + sem assignment ativa) + 1 delivery em
   `searching_driver` (draft→quoted→confirm_quote) + 1 `dispatch_round` aberta
   (`open_dispatch_round`, raio amplo) + 2 `delivery_offers` respondidas com `accept`
   (`respond_to_offer`). Retorna os IDs (delivery, round, offer1, offer2, driver1,
   driver2) como JSON, capturados em variáveis bash via `jq`.
2. **Race** (2 `curl` paralelos via `&` + `wait`, cada um uma chamada RPC auto-commit): os
   dois backends disputam a mesma corrida concorrentemente. Cada resultado cai num
   `/tmp/conc_<name>_<side>.out`.
3. **Assert** (uma chamada SQL sequencial pós-race): lê o estado **do banco**
   (autoridade) + parseia os retornos RPC dos `.out` via `jq`, consolida o veredito.

Sem `dblink`. Sem superuser. Sem senha na linha de comando (usa o PAT em
`~/.supabase/vio10_dev_pat`, lido via `cat` em variável — nunca escrito em arquivo
persistente, nunca commitado).

### D2 — Três races (A e B determinísticas no invariante; C observacional)

- **Test A — dois `claim_delivery` paralelos** (mesma delivery, offers diferentes):
  primitivo de atribuição. Ambos executam `select dr.status … for update` na mesma
  `delivery_requests` → o lock serializa. O vencedor atribui (assignment active,
  delivery `assigned`, offer `won`, R16 perde a outra, fecha a rodada); o perdedor
  re-lê `status='assigned'` → `not_searching_driver`.
  - **Assert**: exatamente 1 `won=true` + 1 `won=false` (`not_searching_driver`);
    exatamente 1 `delivery_assignments` active (`idx_delivery_assignments_active_uk`);
    delivery `assigned`; rodada `closed` com `closed_at`; exatamente 1 offer `won` + 1
    `lost` (R16). Não afirma **qual** driver venceu (o lock race é não-determinístico quanto
    ao vencedor; o **invariante** é determinístico).

- **Test B — dois `select_winner_and_claim` paralelos** (mesmo round): o hazard real de
  produção (orquestrador n8n duplica/rechama o close — retry, webhook duplicado, dois
  workers). Ambos executam `select * from dispatch_rounds … for update` na mesma rodada →
  o lock da rodada serializa. O vencedor pontua + `winner_selected` + `claim_delivery`
  (atribui, fecha a rodada, R16); o perdedor re-lê `status='closed'` → `round_not_open`
  (retorna antes de pontuar/claimar).
  - **Assert**: exatamente 1 `ok=true` `reason='won'` + 1 `ok=false`
    `reason='round_not_open'`; exatamente 1 assignment active; delivery `assigned`; rodada
    `closed`; exatamente 1 offer `won` + 1 `lost`. (O vencedor é o melhor candidato pelo
    scoring — **determinístico** — pois ambos pontuariam igual; mas só um chega a pontuar.)

- **Test C — `select_winner_and_claim` vs `claim_delivery` direto (observacional,
  DB-state only)**: documenta o hazard de lock-ordering (D4). Um SWAC e um
  `claim_delivery` direto disputam a mesma delivery/rodada. Por ordering de lock
  divergente, **pode** haver deadlock (40P01) — o Postgres aborta um, o outro vence. O
  retorno RPC do abortado é não-determinístico (exceção 40P01 vs `not_searching_driver`),
  então o harness **não afirma** retornos RPC aqui — only o **invariante de DB-state**.
  - **Assert**: exatamente 1 assignment active; delivery `assigned`; rodada `closed`;
    exatamente 1 offer `won`. Invariante determinístico no DB, qualquer que seja o
    desfecho da race/deadlock.

### D3 — Invariante do GATE (determinístico no estado do banco)

Para toda race: **exatamente 1 `delivery_assignment` ativa por `delivery_request`**,
**exatamente 1 `delivery_offer` `won`**, delivery termina `assigned`, rodada termina
`closed` com `closed_at`. O **qual** vence pode ser não-determinístico (lock race); o
**invariante** (≤1 ativa) é determinístico e é o que o GATE afirma. Este é o corolário
operacional de ADR-007.

### D4 — Achado: lock-ordering inconsistente (deadlock latente, não-hazard vivo)

Análise dos fluxos de lock revelou uma inconsistência:
- `select_winner_and_claim` (0024): lock **round** `FOR UPDATE` (linha 65-66) → lock
  **delivery** `FOR UPDATE` (linha 78-79). Ordem: **round → delivery**.
- `claim_delivery` (0016): lock **delivery** `FOR UPDATE` (linha 51-54, primeiro
  statement) → `FOR UPDATE OF o` na offer (linha 73) → fecha a rodada via
  `UPDATE dispatch_rounds … WHERE delivery_request_id=… and status='open'` (linha
  117-119, lock implícito na linha da rodada, **não pre-adquirido**). Ordem efetiva:
  **delivery → round-update**.

Se um `claim_delivery` **direto** (chamado fora do SWAC) racear um `select_winner_and_claim`
em **transações separadas** sobre a mesma delivery, há ciclo de wait: SWAC segura round,
espera delivery; claim direto segura delivery, ao tentar fechar a rodada (UPDATE) espera
round. Postgres detecta o deadlock (~`deadlock_timeout`, 40P01) e aborta uma transação —
o **invariante** (≤1 ativa) é preservado, mas o perdedor recebe uma **exceção** em vez de
um retorno limpo `(false, reason)`.

**Não é hazard vivo na produção**: `claim_delivery` é chamado **apenas dentro de**
`select_winner_and_claim` (mesma transação — SWAC já segura delivery+round, o re-lock é
reentrante, sem deadlock). A transição `searching_driver → assigned` só via SWAC→claim
(decisão Sessão 09, CLAUDE.md/BACKEND.md). `claim_delivery` tem `execute` concedido a
`service_role` (0016), então o backend **poderia** chamá-lo direto — mas o caminho
arquitetado é SWAC-only. O Test C existe para **provar empiricamente** que o invariante
sobrevive mesmo a essa inconsistência.

**Recomendação de hardening (adiada — não é GATE, não muda o invariante):** se um futuro
caminho chamar `claim_delivery` direto concorrente com SWAC (ex.: reatribuição de
emergência, integração legada), endurecer o lock order — ter `claim_delivery` adquirir o
lock da rodada `FOR UPDATE` antes do delivery (espelhando SWAC), ou centralizar o close da
rodada fora de `claim_delivery`. Adiado para não desestabilizar o código validado da
Sessão 09; registrado como dívida técnica observada (CODE_REVIEW).

### D5 — Sem migration, sem schema change, sem grant novo

A Sessão 10 é **validação**, não feature. `claim_delivery` (0016) e
`select_winner_and_claim` (0024) já existem e estão validados funcionalmente (Sessão 09).
**Nenhuma migration, nenhuma tabela/coluna/RPC/grant novo.** O harness é um artefato bash
+ SQL de teste, commitado em `supabase/tests/` para reprodutibilidade/auditoria do GATE.

### D6 — Critério de PASS do GATE

- Reset + replay 0001→0024 limpo (24/24) no dev `rtoyfiqngyicqtuzwfhz` (nunca produção).
- Inventário consistente (26 tabelas, RLS 26/26, `select_winner_and_claim` system-only,
  `anon`=0 em public).
- Todas as 8 suítes existentes continuam PASS (regression): invariants 13/13, rpcs 48/48,
  authz 21/21, auth_lifecycle 34/34, creation 37/37, pricing 62/62, dispatch 65/65, bid
  61/61.
- **Test A, B, C: invariante (D3) sustentado em ≥5 execuções reais paralelas por race**
  (determinismo do invariante sob concorrência genuína, não uma só corrida sorteada).
- **Não simular PASS.** Se o invariante falhar em qualquer execução, declarar FAIL e
  investigar (não declarar GATE PASS).

### D7 — Ambiente e segurança

- Dev `rtoyfiqngyicqtuzwfhz` apenas (us-west-2, Postgres 17). **Nunca produção.**
- **Nunca** executar migrations experimentais em projeto com dados reais.
- Se não houver ambiente seguro: declarar **BLOCKED**.
- PAT em `~/.supabase/vio10_dev_pat` (chmod 600, lido via `cat` em var, nunca commitado,
  nunca escrito em arquivo persistente pelo Claude).
- Acesso via `curl` + Management API (`User-Agent: supabase-cli/2.115.0`); MCP supabase
  plugin não alcança este dev.
- Senha do banco nunca na linha de comando; nunca consultar `pg_authid.rolpassword`.

## Consequências

- **GATE de produção (ADR-007) formalmente validado em concorrência real**: ≤1
  assignment ativa por corrida, provado sob backends concorrentes (não simulado).
- O mecanismo (curls paralelos ao Management API) substitui `dblink` no arcabouço de
  teste de concorrência — reutilizável para futuros gates de concorrência.
- Lock-ordering (D4) registrado como dívida técnica observada; não bloqueia o GATE pois
  não é hazard vivo (claim_delivery só roda dentro de SWAC).
- **Veredito GO → Sessão 11** (ciclo completo: máquina de estados + proof of delivery).

## Referências

`ADR-007` (atribuição atômica), `ADR-014` (bid engine, SWAC), `ADR-006` (ACEITAR≠GANHAR),
`BACKEND.md` §4/§4.5, `docs/DELIVERY_LIFECYCLE.md`, `docs/BID_ENGINE.md`,
`docs/SECURITY.md`, `CLAUDE.md` (regra mestra, estado atual).