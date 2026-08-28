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
- ETA até a coleta (menor é melhor) — via RoutingProvider;
- distância até a coleta (menor é melhor) — via RoutingProvider.

Fatores **preparados, mas ponderados a 0 até houver histórico confiável**:

- rating;
- completion rate;
- cancellation rate;
- velocidade de resposta.

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
  **não atribui**. A seleção/claim (`select_winner_and_claim` / `claim_delivery`)
  fica para o fechamento da rodada (Sessão 09/10).

## Concorrência / atomicidade (gate de produção — Sessão 10)

A atribuição é protegida por:

- constraint parcial `UNIQUE (delivery_request_id) WHERE status='active'` em
  `delivery_assignments`;
- RPC `claim_delivery()` com `SELECT … FOR UPDATE`;
- idempotência: retries/webhooks duplicados não duplicam atribuição.

Mesmo que duas rodadas/instâncias do n8n tentem atribuir simultaneamente, o banco
garante **um único** vencedor. Detalhes em `ARCHITECTURE.md` seção 6 e `BACKEND.md`.