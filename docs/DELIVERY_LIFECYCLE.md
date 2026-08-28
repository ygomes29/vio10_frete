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
> `searching_driver → assigned` continua via `claim_delivery` (0013), mas a **seleção do
> vencedor** (fechar rodada, scoring, escolher) é a **Sessão 09-10** (GATE) — a Sessão 08
> só abre rodadas (`open_dispatch_round`, system-only) e cria offers.
2. Cada transição importante valida:
   - estado atual permite o destino;
   - ator é autorizado para a transição;
   - invariantes (ex.: não transitar para `delivered` sem proof of delivery válida).
3. Cada transição importante gera um `delivery_event` (auditoria) com ator,
   timestamp, estado anterior, estado novo, `correlation_id`, motivo quando houver.
4. Transições são atômicas com a escrita do novo estado + evento.

## Atores por transição (preview — detalhado na Sessão 11)

| Transição | Autorizado |
|---|---|
| draft → quoted | sistema (pricing, `create_quote` — ADR-012) |
| quoted → searching_driver | business_owner/user, operator, admin, sistema (`confirm_quote` — ADR-013; confirma a cotação pendente) |
| searching_driver → assigned | sistema (claim atômico após seleção — Sessão 09-10) |
| searching_driver → expired | sistema (rodadas esgotadas) |
| → cancelled (pré-atribuição) | business_owner/user, operator, admin |
| assigned → driver_to_pickup | driver (ou sistema via confirmação) |
| … → at_pickup / picked_up / in_transit | driver |
| → delivered | sistema (após proof of delivery válida) |
| reatribuição / failed | operator/admin/driver (conforme regra) |

## Prova de entrega

Conclusão exige POD validado pelo backend (foto e/ou OTP + nome do recebedor + hora;
geolocalização quando autorizada). O frontend **não** marca `delivered`; o backend
valida o POD e dispara a transição. Detalhes na Sessão 12.