# ADR-006 — bidding round antes da atribuição (ACEITAR ≠ GANHAR)

- **Status**: Aprovado
- **Data**: 2026-08-27
- **Sessão**: 02

## Contexto

A Sessão 01 sugeriu que ACEITAR chamava `claim_delivery()` imediatamente e o
primeiro a aceitar vencia. **Rejeitado**: isso elimina o motor de lances — um
candidato que respondesse dois segundos depois com valor mais competitivo não
teria chance.

## Decisão

No ViO10, **ACEITAR ≠ GANHAR**. ACEITAR significa "estou disposto a fazer a corrida
pelo valor ofertado" — conceitualmente um **lance igual a `driver_offer_cents`**.

A disputa ocorre **dentro de `searching_driver`** (não como estado principal
`bidding`), via `dispatch_rounds`/`delivery_offers`/`bids`:

- A rodada coleta ACCEPT/COUNTER_BID/DECLINE numa **janela configurada**.
- Durante a janela, **não** atribuir ao primeiro ACCEPT.
- Ao fechar: coletar válidas → scoring determinístico → ordenar → escolher
  vencedor → `claim_delivery()` atômico.

Early close futuro só por **política determinística explícita**
(ex.: `candidate_score >= fast_accept_threshold`), nunca "primeiro que aceitar".

## Consequências

- Lances mais competitivos (ou melhores ETAs) podem vencer mesmo chegando depois.
- O vencedor **não** é necessariamente o menor preço (scoring combina fatores).
- A atribuição continua protegida atomicamente (ADR-007) — o Bid Engine só
  escolhe; `claim_delivery()` confirma.
- Scoring é determinístico, configurável e auditável.

## Referências

`docs/BID_ENGINE.md`, `docs/DISPATCH_ENGINE.md`, ADR-007.