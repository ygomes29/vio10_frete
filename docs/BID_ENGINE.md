# docs/BID_ENGINE.md — Motor de lances

> **Este é o diferencial do ViO10.** Documento de referência para as Sessões 09 e 10.
> Incorpora a **correção crítica** da Sessão 01: ACEITAR não é vitória imediata.

## Princípio fundamental

> **ACEITAR ≠ GANHAR.**

No ViO10, ACEITAR significa: *"estou disposto a executar a corrida pelo valor
ofertado"*. Conceitualmente, é um **lance igual a `driver_offer_cents`**.

Não existe "primeiro que clicar ACEITAR ganha". A corrida não é atribuída no instante
do clique. A rodada coleta candidatos numa **janela configurada**, fecha, pontua os
candidatos, escolhe o vencedor e só então executa `claim_delivery()` **atomicamente**.

## Por que não atribuir no primeiro ACEITAR

Se atribuíssemos no clique:
- João ACEITAR → ganha instantaneamente;
- Pedro responderia R$ 10 dois segundos depois, mas a disputa já terminou;
- não teríamos um motor de lances — teríamos "primeiro a clicar vence".

O ViO10 coleta propostas durante a janela e escolhe pelo **score**, permitindo que
lances mais competitivos (ou melhores ETAs) vençam mesmo chegando depois.

## Respostas do entregador

Cada entregador, numa oferta dentro de uma rodada, pode:

| Resposta | Significado | Registro |
|---|---|---|
| **ACCEPT** | aceita o valor ofertado | `bid_amount_cents = driver_offer_cents` |
| **COUNTER_BID** | propõe outro valor | `bid_amount_cents = valor do lance` |
| **DECLINE** | recusa | removido da rodada/oferta |

Todas as respostas passam pelo backend (idempotentes, link assinado). **Não** alteram
estado via DataCrazy diretamente.

## Janela da rodada

- A rodada tem **timeout** configurável.
- Durante a janela, coletamos ACCEPT/COUNTER_BID/DECLINE.
- **Durante** a janela: **não** atribuir ao primeiro ACCEPT.
- Ao **fechar** a rodada (timeout ou early close autorizado):

  1. coletar respostas válidas;
  2. eliminar expiradas/inválidas (offer expirada, driver ocupado, corrida já
     atribuída, lance inválido);
  3. calcular score de cada candidato válido;
  4. ordenar candidatos;
  5. selecionar o vencedor;
  6. tentar `claim_delivery()` **atomicamente**;
  7. se perder (concorrência/indisponibilidade): tratar determinísticamente
     (ex.: nova rodada);
  8. confirmar vencedor;
  9. as demais offers ainda respondíveis da **corrida inteira** (em qualquer rodada,
     não só da rodada vencedora) viram `lost` — feito pelo próprio `claim_delivery`
     (filtra por `delivery_request_id`, regra **R16**). Evita respostas tardias
     inconsistentes e race conditions cross-round após a atribuição oficial;
  10. notificar participantes.

## Early close (futuro, opcional)

A arquitetura **prepara** para encerrar a rodada antes do timeout, mas **nunca** pela
regra implícita "primeiro que aceitar ganha". Early close só por **política
determinística explícita**, por exemplo:

```
candidate_score >= fast_accept_threshold
```

No MVP, simplesmente esperamos o pequeno timeout da rodada.

## Scoring (MVP)

Determinístico, auditável, com pesos **configuráveis**.

Fatores **usados no MVP** (só dados realmente disponíveis):

- `bid_amount_cents` — valor solicitado pelo entregador (menor é melhor);
- distância até a coleta (`ST_Distance` PostGIS, `driver_locations.position` vs
  `pickup_point`; menor é melhor) — proxy operacional de ETA (RoutingProvider na
  Sessão 20; até lá, ETA peso 0).

Fatores **preparados, mas ponderados a 0 até houver histórico confiável**:

- ETA via RoutingProvider (Sessão 20);
- rating;
- completion rate;
- cancellation rate;
- velocidade de resposta.

### Implementação (Sessão 09, ADR-014)

A seleção vive em **1 RPC system-only `select_winner_and_claim`** (terceiro system-only
após `create_quote`/`open_dispatch_round`), `SECURITY DEFINER` no Postgres. O
orquestrador (backend) chama quando a janela fecha:

- **Coleta candidatos válidos** = offers respondidas (`accepted`/`counter_bid`) com
  driver **ainda elegível no close** (re-valida eligibility da Sessão 08: active+available
  +veículo compatível+sem assignment ativa+localização fresca+`ST_DWithin` no raio da
  própria rodada) + offer não expirada. Declined excluída; pending expira.
- **Pontua** via normalização **min-max** por window function: `norm_bid = (bid - min_bid)
  / nullif(max_bid - min_bid, 0)` (todos iguais → 0), `norm_dist` análogo. Lower-is-better
  → goodness = `1 - norm`. `score = p_weight_price * (1 - norm_bid) + p_weight_distance *
  (1 - norm_dist)` (`numeric` adimensional, **não** dinheiro; maior = melhor). Se um
  peso = 0 o fator é ignorado; ambos 0 → `invalid_param`.
- **Tie-break determinístico** (não ditado por ADR-006): `score desc, dist_m asc,
  responded_at asc, driver_id asc`. Distância primeiro, depois rapidez de resposta,
  depois `driver_id` (estável entre runs).
- **Pesos como params do caller (backend), sem tabela de config** no MVP — espelha
  `open_dispatch_round` (insumos do orquestrador). `scoring_config` table adiada.
- **Sem vencedor** (0 candidatos): fecha a rodada manualmente + expira offers pending +
  emite `round_closed` (reason=`no_candidates`) + retorna `no_candidates` (orquestrador
  abre a próxima rodada de raio maior; a rodada `closed` libera o guard `round_already_open`).
  Delivery permanece `searching_driver`.
- **Com vencedor**: emite `winner_selected` (scores de todos os candidatos no `metadata`
  — rastro **explicável**) + chama `claim_delivery` internamente (atômico: atribui, fecha
  a rodada, R16 perde demais offers, emite `driver_assigned`). Se claim falhar por race
  (`already_assigned`/`not_searching_driver`) → fecha nossa rodada como superseded +
  retorna o reason (sem retry automático — decisão do orquestrador).
- **Sem `winner_*` em `dispatch_rounds`**: o vencedor vive em `delivery_assignments`
  (linha `active`) + `delivery_offers.status='won'` + `delivery_events`. **Nenhuma
  tabela/coluna nova.**
- **System-only**: `auth.uid() IS NOT NULL` → `not_authorized`; `revoke public` + `execute`
  só a `service_role` (`authenticated` sem EXECUTE — defesa em profundidade). **Trust
  boundary dos pesos de scoring:** vêm do backend (config do orquestrador), não do
  business — um business passando pesos forjaria o vencedor. Idempotência por estado: chamar
  em rodada já `closed` → `round_not_open`.

**GATE (Sessão 10)**: a atomicidade de `claim_delivery` já é testada funcionalmente
(exatamente 1 assignment ativo, `already_assigned` no pós-race). O harness de
**concorrência real** (dois `select_winner_and_claim`/`claim_delivery` paralelos via
`dblink`/advisory lock) é o gate formal de produção (ADR-007) — Sessão 10.

### Requisitos do score

- **Determinístico**: mesma entrada → mesma saída.
- **Pesos configuráveis** (não hardcoded espalhados).
- **Normalização** de variáveis com escalas diferentes (ex.: centavos vs minutos
  vs metros) antes de combinar.
- **Explicável**: o vencedor deve poder ser justificado ("venceu porque teve menor
  valor e menor ETA, normalizados"). Nunca fórmula impossível de auditar.
- O vencedor **não** precisa ser obrigatoriamente o menor preço.

## Registro (auditoria)

Cada resposta e cada rodada registram:

- `driver_id`, `delivery_request_id`, `dispatch_round_id`, `delivery_offer_id`;
- `offer_amount_cents`, `bid_amount_cents`;
- `response` (ACCEPT/COUNTER_BID/DECLINE);
- `timestamp`;
- `round`;
- `status`;
- motivo da seleção quando aplicável;
- `correlation_id`.

## Invariantes

- Uma oferta **expirada** não pode ser aceita.
- Uma corrida **já atribuída** rejeita novas respostas (retorna `already_assigned`).
- Resposta **atrasada** não toma corrida já atribuída.
- Um entregador não pode enviar lances ilimitados indevidamente (limite por rodada,
  configurável).
- `claim_delivery()` continua a **garantia final**: mesmo após o Bid Engine
  escolher, o candidato só é vencedor oficial após o claim atômico confirmar.

## Modelagem no banco (Sessão 03)

- `bids` com `UNIQUE(delivery_offer_id, driver_id)` → **uma resposta válida por
  oferta** (sem negociação infinita no MVP).
- FK composto `bids(delivery_offer_id, driver_id) → delivery_offers(id, driver_id)`
  → um bid **não pode** referenciar offer de outro driver.
- CHECK em `bids`: `accept`/`counter_bid` exigem `bid_amount_cents > 0`; `decline`
  exige `bid_amount_cents IS NULL`.
- `respond_to_offer()` é idempotente (`already_responded` / `idempotent_replay`) e
  **não atribui**. A seleção é via `select_winner_and_claim` (Sessão 09, ADR-014), que
  pontua candidatos válidos no close e chama `claim_delivery` atômico internamente.

## Concorrência / atomicidade (gate de produção — Sessão 10)

A atribuição é protegida por:

- constraint parcial `UNIQUE (delivery_request_id) WHERE status='active'` em
  `delivery_assignments`;
- RPC `claim_delivery()` com `SELECT … FOR UPDATE`;
- idempotência: retries/webhooks duplicados não duplicam atribuição.

Mesmo que duas rodadas/instâncias do n8n tentem atribuir simultaneamente, o banco
garante **um único** vencedor. Detalhes em `ARCHITECTURE.md` seção 6 e `BACKEND.md`.