# ADR-016 — Ciclo completo pós-`assigned` + POD gate

- **Status**: Aprovado
- **Data**: 2026-08-28
- **Sessão**: 11

## Contexto

A Sessão 10 fechou o **GATE de produção** (atribuição atômica em concorrência real —
ADR-007/ADR-015, PASS). A corrida chega a `assigned` com um entregador eleito. Falta o
**ciclo completo pós-atribuição**: o entregador avança
`assigned → driver_to_pickup → at_pickup → picked_up → in_transit → delivered`, com
cancelamento/falha/reatribuição auditados, e a transição `delivered` **gated por proof of
delivery** validada pelo backend.

A regra mestra é explícita: **"O frontend não marca `delivered`; o backend valida o POD e
dispara a transição."** E "IA não inventa… status." Toda transição crítica passa pela
função central transacional `transition_delivery` (0016, `SECURITY DEFINER`).

### Estado atual (0016)

- `transition_delivery` já codifica a **matriz estrutural completa** de transições (inclui
  todos os estados pós-`assigned` + reatribuição + `failed`/`cancelled`), supersede a
  assignment ativa em reatribuição, incrementa `reassignment_count`, emite `delivery_events`.
- Authz **coarse**: system / platform admin (super/admin/operator) / driver com assignment
  ativa / membro da org — **qualquer um pode disparar qualquer transição permitida**. Não
  há matriz por (ator × transição).
- `reassignment_count` existe mas **sem teto** (reatribui para sempre).
- `in_transit → delivered` **não exige POD**. A tabela `proof_of_delivery` (0011) existe mas
  **nenhuma RPC escreve nela**; `authenticated` sem INSERT grant/policy → write só via
  `SECURITY DEFINER`. Sem unique por `(delivery_request_id, pod_type)`.
- `cancelled_reason`/`failed_reason` existem em `delivery_requests` mas `transition_delivery`
  **não os seta** (só timestamps).
- `pod_submitted` **não existe** no enum `delivery_event_type`.

### Callers internos de `transition_delivery` (preservar)

`create_quote` (0022, system-only → `draft→quoted`); `confirm_quote` (0023, user-scoped →
`quoted→searching_driver`). `claim_delivery`/`select_winner_and_claim` **não** chamam
`transition_delivery` (emitem `driver_assigned` direto) — não afetados pelo refactor; o
GATE da Sessão 10 permanece íntegro.

### Sutileza de auth em cadeia DEFINER

`auth.uid()` lê o JWT GUC da sessão e **não muda** com `SECURITY DEFINER`. Logo um RPC
driver-scoped chamado pelo app do entregador vê `auth.uid() = driver` em toda a cadeia
interna — não pode acionar uma transição system-only internamente. Isso determina o modelo
**two-phase** do POD (D4): o driver submete a evidência; o sistema confirma.

## Decisão

### D1 — Matriz de authz por (ator × transição) dentro de `transition_delivery`

Resolve o ator em uma **classe de papel** e intersecta a matriz estrutural M (from→to) com a
matriz de papel R[role]:

- **system** (auth.uid null): todas de M.
- **admin** (super_admin/admin/operator): todas de M **exceto** as system-only
  `{draft→quoted, searching_driver→assigned, searching_driver→expired, in_transit→delivered}`
  (admin não cota/atribui/expira/entrega direto; usa a RPC dedicada ou é automatizado). Pode
  avançar micro-estados do driver (override operacional), cancelar, falhar, reatribuir.
- **driver** (driver com assignment ativa na corrida): só
  `{assigned→driver_to_pickup, driver_to_pickup→at_pickup, at_pickup→picked_up,
  picked_up→in_transit}`. Avanço forward-only. **Não** pode `delivered`/reatribuir/cancelar/
  falhar (reporta issue por fluxo próprio — Sessão 12+).
- **business** (membro da org): `{draft→cancelled, quoted→cancelled, quoted→searching_driver,
  searching_driver→cancelled}`. Cancela pré-atribuição + confirma cotação (via
  `confirm_quote`). **Não** cancela pós-atribuição, não avança driver.

Ordem: checa M primeiro (`invalid_transition` se结构性mente impossível), depois R
(`not_authorized` se o papel não pode). Preserva callers internos: `create_quote`
(system→draft→quoted ✓), `confirm_quote` (business/admin→quoted→searching_driver ✓).
**Adiciona `draft→cancelled` à matriz M** (ausente hoje; business pode cancelar draft).
Assinatura **inalterada** (`create or replace` limpo, sem drop).

### D2 — Limite de reatribuição via `p_metadata->>'max_reassignments'`

Em toda reatribuição (`assigned`/`driver_to_pickup`/`in_transit`/`at_pickup →
searching_driver`), lê `v_max := nullif(p_metadata->>'max_reassignments','')::int`. Se
`v_max is not null and reassignment_count >= v_max` → retorna
`(false, 'reassignment_limit_reached')` **sem mutar** (o caller/orquestrador então emite
`→failed`). Sem `v_max` = ilimitado (back-compat com callers existentes). Sem tabela de
config (MVP) — param do caller, como pesos de scoring (ADR-014) e raio de dispatch (ADR-013).

### D3 — `cancelled_reason`/`failed_reason` capturados do metadata

Ao transitar para `cancelled`/`failed`, seta a coluna correspondente de
`p_metadata->>'reason'` (além do timestamp e do evento). Hoje essas colunas existem mas
nunca são escritas — correção.

### D4 — POD two-phase: `submit_proof_of_delivery` (driver-scoped) + `confirm_delivery` (system-only)

- **`submit_proof_of_delivery`** (`SECURITY DEFINER`, grants `service_role` + `authenticated`):
  autoriza o **driver com assignment ativa** (ou system path se auth.uid null). Valida
  completude (D6), insere em `proof_of_delivery`, emite `pod_submitted`. **Não transita.**
- **`confirm_delivery`** (`SECURITY DEFINER`, **system-only** — `auth.uid() is not null` →
  `not_authorized`; grant `service_role` somente): valida que existe POD `pod_type='delivery'`
  e chama `transition_delivery(id,'delivered','system',null, metadata{pod_id}, correlation)`,
  que re-valida o gate (D5, defense in depth) e transita. Espelha `create_quote`/`SWAC`
  (system-only, trust boundary). Em produção, **n8n** chama `confirm_delivery` (webhook sobre
  `pod_submitted`); pré-n8n, o backend/service layer chama.
- **Submeter POD ≠ entregue** — análogo a ACEITAR ≠ GANHAR (ADR-006). O driver fornece a
  evidência; o sistema confirma.

### D5 — POD gate dentro de `transition_delivery` para `in_transit→delivered`

Após a checagem de matriz, antes do UPDATE: se `p_to_status='delivered'` e **não existe** POD
`pod_type='delivery'` para a corrida → `(false, 'pod_required')`. Impede **qualquer** path
(inclusive system direto sem POD) de entregar sem prova. `confirm_delivery` pré-valida (D4) e
o gate re-valida — defense in depth.

### D6 — Completude do POD (MVP) na `submit_proof_of_delivery`

- `pod_type='delivery'`: exige `(storage_path is not null or otp_code is not null)` **e**
  `receiver_name is not null` → senão `invalid_pod`.
- `pod_type='pickup'`: exige ao menos um de `storage_path`/`otp_code`/`notes` → senão
  `invalid_pod`. **Não** gatinga `picked_up` no MVP (registrado, sem transição).
- Estado: `delivery` exige `status='in_transit'`; `pickup` exige status em
  `('driver_to_pickup','at_pickup','picked_up','in_transit')` → senão `wrong_state`.
- Unique `(delivery_request_id, pod_type)` → segundo submit → `pod_already_submitted`
  (captura `unique_violation`).
- Profundidade (foto em Storage, OTP gerado/enviado ao recebedor, geolocation validada,
  receiver verification) → **Sessão 12**.

### D7 — Ator via `auth.uid()`; eventos

`submit_proof_of_delivery`: actor `driver` (auth.uid) ou `system`; emite `pod_submitted`
com metadata `{pod_id, pod_type}`. `confirm_delivery`: actor `system`; a transição emite
`delivered` (já na matriz) com metadata `{pod_id}`. **Novo enum** `pod_submitted` (D9).
`transition_delivery` refinada **não** referencia o novo enum.

### D8 — Sem tabela nova; 1 valor de enum + 1 constraint + 2 RPCs + 1 RPC refinada

Schema changes: `alter type ... add value 'pod_submitted'`; `unique (delivery_request_id,
pod_type)` em `proof_of_delivery`. **Não** adicionar `captured_by` (auditoria via
`delivery_events.pod_submitted` actor_id basta). **Não** adicionar `verified` (Sessão 12).
Sem novos grants de DML a `authenticated` (INSERT em POD só via DEFINER; RLS INSERT
permanece default-deny).

### D9 — Split em 2 migrations (gotcha `ALTER TYPE ... ADD VALUE` in-tx)

Um valor de enum adicionado numa transação pode não ser referenciável na mesma transação.
Logo: **0025** adiciona o enum value + o unique constraint (schema prep, sem função que
referencie o novo valor); **0026** adiciona/as RPCs (referenciam `'pod_submitted'` já
committed). Cada migration = transação separada no replay (curl por arquivo).

## Consequências

- O ciclo pós-`assigned` fica **completo e auditável**: todo avanço/cancelamento/falha/
  reatribuição passa por `transition_delivery` com ator resolvido de `auth.uid()`, e toda
  entrega exige POD validado pelo backend.
- A matriz ator×transição **restringe** o que cada papel pode fazer (antes, qualquer papel
  autorizado fazia qualquer transição). Pode quebrar asserções de teste antigas que assumiam
  permissão ampla — revisado em `test_vio10_rpcs` (TR8: POD gate).
- `delivered` é **system-only** via `confirm_delivery`; o driver não pode auto-certificar
  entrega. O happy-path depende de um caller system (n8n ou service layer) — fio condutor da
  Sessão 12/13.
- Reatribuição tem teto configurável pelo orquestrador; sem teto = ilimitado (back-compat).
- Sem tabela nova; change mínimo de schema (enum + constraint).

## Fora do escopo (adiado)

- **POD completo** (foto em Storage, OTP ao recebedor via WhatsApp, geolocation, verificação
  do recebedor, gating de pickup POD, auto-confirm orquestrado) → **Sessão 12**.
- **Orquestração n8n** (webhook sobre `pod_submitted` → `confirm_delivery`) → Sessão 13-14.
- **Reporte de issue pelo driver** (fluxo distinto) → Sessão 12+.
- **Limite de reatribuição em config** → MVP via metadata.
- **Hardening do lock-ordering** (dívida ADR-015 D4) → independente; permanece deferido.