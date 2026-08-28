# ADR-008 — Valores financeiros em centavos inteiros

- **Status**: Aprovado
- **Data**: 2026-08-27
- **Sessão**: 02

## Contexto

Float/decimal de precisão dupla em dinheiro gera erros de arredondamento e
comparações inconsistentes — inaceitável em um sistema com cobrança, repasse e
margem.

## Decisão

Todos os valores financeiros são **inteiros em centavos**. Currency `BRL`.

Exemplos: `R$ 10,90 = 1090`; `R$ 100,00 = 10000`.

Nomes explícitos: `customer_price_cents`, `driver_offer_cents`,
`driver_earning_cents`, `platform_fee_cents`, `bid_amount_cents`. Campo `currency`
preservado quando fizer sentido.

## Consequências

- Sem float em cálculos financeiros.
- Comparações e somas exatas.
- Formatação para exibição ocorre só na borda (frontend), nunca no cálculo.

## Referências

`docs/PRICING_ENGINE.md`, `ARCHITECTURE.md`.