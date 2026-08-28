# docs/DELIVERY_LIFECYCLE.md — Ciclo de vida da entrega

## Estados principais

```
draft
quoted
searching_driver
assigned
driver_to_pickup
at_pickup
picked_up
in_transit
delivered          (terminal)
cancelled          (terminal)
failed             (terminal)
expired            (terminal — sem entregador após todas as rodadas)
```

`bidding` **não** é estado principal. A disputa ocorre *dentro* de
`searching_driver`, via `dispatch_rounds`, `delivery_offers`, `bids`.

## Transições (caminho feliz)

```
draft → quoted → searching_driver → assigned → driver_to_pickup
→ at_pickup → picked_up → in_transit → delivered
```

## Transições de exceção

- **Cancelar antes da atribuição**: `draft|quoted|searching_driver → cancelled`
  (por empresa, operador ou sistema).
- **Sem entregador**: `searching_driver → expired` após esgotar rodadas
  configuradas. Distinto de `failed` (que é problema durante a execução).
- **Problema na execução** (no-show, endereço incorreto, problema na coleta/entrega):
  `assigned → searching_driver` (reatribuição, com contador limitado) ou
  `→ failed` quando irrecuperável.
- **Entregador cancela**: `assigned|driver_to_pickup|at_pickup → searching_driver`
  (reatribuição) ou `→ failed`/`cancelled` conforme regra.
- **Reatribuição** tem limite configurável de tentativas.

## Regras da máquina de estados

1. **Nenhuma parte do sistema altera `status` diretamente.** Toda transição crítica
   passa por função central transacional `transition_delivery()` no Postgres.

> **Implementação (Sessão 03):** `transition_delivery()` (em
> `supabase/migrations/0013_rpcs.sql`) já codifica a matriz de transições permitidas,
> atualiza o timestamp correspondente ao destino, supersede a assignment anterior em
> reatribuição (`assigned`/`driver_to_pickup`/`in_transit` → `searching_driver`) e
   insere `delivery_event`. Autorização por ator será reforçada na Sessão 04/11.

> **Implementação (Sessão 07):** `draft → quoted` é via `create_quote` (system-only,
> ADR-012). **Implementação (Sessão 08):** `quoted → searching_driver` é via
> `confirm_quote` (user-scoped: business/operator/admin/membro da org ou system, ADR-013
> D1) — confirma a cotação pendente (`delivery_quotes.status='pending'` → `confirmed`,
> `confirmed_at` setado), com atomicidade transition-first (sem quote confirmed órfã).
> A Sessão 08 só abre rodadas (`open_dispatch_round`, system-only) e cria offers.
> **Implementação (Sessão 09):** `searching_driver → assigned` é via
> `select_winner_and_claim` (system-only, ADR-014) → `claim_delivery` (0016) atômico. A RPC
> fecha a rodada, pontua candidatos válidos (min-max de `bid_amount_cents` + distância
> PostGIS, pesos de param, tie-break determinístico), escolhe o vencedor e chama
> `claim_delivery` internamente (atribui, fecha a rodada, R16 perde demais offers, emite
> `driver_assigned`). Sem vencedor → fecha a rodada + `no_candidates` (orquestrador abre a
> próxima rodada de raio maior). **GATE de produção (Sessão 10)**: a atomicidade em
> concorrência real é validada formalmente via harness paralelo (ADR-007).
> **Implementação (Sessão 11, ADR-016):** `transition_delivery` é **refinada** com a matriz
> de authz por (ator × transição) (D1) — antes, qualquer papel autorizado podia disparar
> qualquer transição permitida; agora cada papel tem seu subconjunto. Adiciona limite de
> reatribuição via `metadata.max_reassignments` (D2), `cancelled_reason`/`failed_reason` do
> metadata (D3), POD gate em `delivered` (D5) e `draft→cancelled` em M. O ciclo pós-
> `assigned` (`driver_to_pickup → at_pickup → picked_up → in_transit → delivered`) é
> agora exercitado por uma suíte dedicada (`test_vio10_lifecycle.sql`, 65 asserções).
2. Cada transição importante valida:
   - estado atual permite o destino (matriz estrutural M → `invalid_transition`);
   - ator é autorizado para a transição (matriz de papel R → `not_authorized`);
   - invariantes (ex.: não transitar para `delivered` sem proof of delivery válida — POD
     gate, ADR-016 D5).
3. Cada transição importante gera um `delivery_event` (auditoria) com ator,
   timestamp, estado anterior, estado novo, `correlation_id`, motivo quando houver.
4. Transições são atômicas com a escrita do novo estado + evento.

## Atores por transição (matriz ator × transição — ADR-016 D1, Sessão 11)

O ator é resolvido de `auth.uid()` em `transition_delivery` (SECURITY DEFINER) numa
**classe de papel**: `system` (auth.uid null), `admin` (super_admin/admin/operator),
`driver` (driver com assignment ativa na corrida), `business` (membro da org). A matriz
estrutural M (from→to) é checada primeiro (`invalid_transition`); depois a matriz de
papel R (`not_authorized`). As transições marcadas **RPC dedicada** não passam por
`transition_delivery` direto — têm a própria RPC (system-only ou user-scoped).

| Transição | system | admin | driver | business | Via |
|---|---|---|---|---|---|
| draft → quoted | ✓ | ✗ | ✗ | ✗ | `create_quote` (system-only, ADR-012) |
| draft → cancelled | ✓ | ✗ | ✗ | ✓ | `transition_delivery` |
| quoted → searching_driver | ✓ | ✗ | ✗ | ✓ | `confirm_quote` (user-scoped, ADR-013) |
| quoted → cancelled | ✓ | ✗ | ✗ | ✓ | `transition_delivery` |
| searching_driver → assigned | ✓ | ✗ | ✗ | ✗ | `select_winner_and_claim` (system-only, ADR-014) |
| searching_driver → cancelled | ✓ | ✓ | ✗ | ✓ | `transition_delivery` |
| searching_driver → expired | ✓ | ✗ | ✗ | ✗ | `transition_delivery` (orquestrador) |
| searching_driver → failed | ✓ | ✓ | ✗ | ✗ | `transition_delivery` |
| assigned → driver_to_pickup | ✓ | ✓ | ✓ | ✗ | `transition_delivery` |
| assigned → searching_driver (reatribuição) | ✓ | ✓ | ✗ | ✗ | `transition_delivery` (limite D2) |
| assigned → failed / cancelled | ✓ | ✓ | ✗ | ✗ | `transition_delivery` |
| driver_to_pickup → at_pickup | ✓ | ✓ | ✓ | ✗ | `transition_delivery` |
| driver_to_pickup → searching_driver (reatribuição) | ✓ | ✓ | ✗ | ✗ | `transition_delivery` |
| at_pickup → picked_up | ✓ | ✓ | ✓ | ✗ | `transition_delivery` |
| at_pickup → searching_driver / failed | ✓ | ✓ | ✗ | ✗ | `transition_delivery` |
| picked_up → in_transit | ✓ | ✓ | ✓ | ✗ | `transition_delivery` |
| in_transit → delivered | ✓ | ✗ | ✗ | ✗ | `confirm_delivery` (system-only, ADR-016 D4) |
| in_transit → failed / searching_driver (reatribuição) | ✓ | ✓ | ✗ | ✗ | `transition_delivery` |

Notas:
- **admin** perde as system-only `{draft→quoted, searching_driver→assigned,
  searching_driver→expired, in_transit→delivered}` — usa a RPC dedicada ou é automatizado.
  Pode avançar micro-estados do driver (override operacional), cancelar, falhar, reatribuir.
- **driver** só avanço forward-only; **não** pode `delivered`/reatribuir/cancelar/falhar
  (reporta issue por fluxo próprio — Sessão 12+).
- **business** cancela pré-atribuição + confirma cotação; **não** cancela pós-atribuição,
  não avança driver.
- **reatribuição** (`assigned`/`driver_to_pickup`/`in_transit`/`at_pickup → searching_driver`)
  supersede a assignment ativa (`ended_reason='reassigned'`), incrementa
  `reassignment_count`, e respeita o teto de `metadata.max_reassignments` (D2) — excedido →
  `reassignment_limit_reached` **sem mutar** (orquestrador emite `→failed`).

## Prova de entrega (POD) — two-phase (ADR-016 D4/D5/D6, Sessão 11)

Conclusão exige POD validado pelo backend. O frontend/driver **não** marca `delivered`;
o backend valida o POD e dispara a transição. **Submeter POD ≠ entregue** (análogo a
ACEITAR ≠ GANHAR, ADR-006) — o driver fornece a evidência; o sistema confirma.

- **`submit_proof_of_delivery`** (driver-scoped: driver com assignment ativa, ou system):
  valida completude (MVP: delivery exige `storage_path`/`otp_code` **e** `receiver_name`;
  pickup exige ao menos um de `storage_path`/`otp_code`/`notes`) + estado correto (delivery
  exige `in_transit`; pickup exige `driver_to_pickup`/`at_pickup`/`picked_up`/`in_transit`);
  insere em `proof_of_delivery` (unique `(delivery_request_id, pod_type)` → segundo submit
  = `pod_already_submitted`); emite `pod_submitted`. **Não transita.**
- **`confirm_delivery`** (**system-only**): valida que existe POD `pod_type='delivery'`
  (senão `pod_required`) e chama `transition_delivery('delivered')`, que **re-valida** o
  POD gate (D5 — defense in depth) e transita `in_transit → delivered`. Em produção, **n8n**
  chama `confirm_delivery` (webhook sobre `pod_submitted`); pré-n8n, o backend/service
  layer chama.
- **POD gate** (D5): dentro de `transition_delivery`, `in_transit → delivered` exige POD
  delivery — impede **qualquer** path (inclusive system direto sem POD) de entregar sem
  prova.

**Profundidade adiada (Sessão 12):** foto em Storage (URL assinada), geração/entrega de
OTP ao recebedor via WhatsApp, validação de geolocalização, verificação do recebedor,
gating de pickup POD em `picked_up`, auto-confirm orquestrado.