# ADR-007 — Atribuição atomicamente protegida pelo banco

- **Status**: Aprovado
- **Data**: 2026-08-27
- **Sessão**: 02

## Contexto

Atribuir duas corridas a dois entregadores simultaneamente, ou gerar atribuições
duplicadas por retry/webhook, é o risco crítico do produto. Não pode depender de
frontend, timing do n8n, variável temporária ou ordem de mensagens.

## Decisão

Garantir no **banco** que uma `delivery_request` tem no máximo uma
`delivery_assignment` ativa:

1. **Constraint parcial**: `UNIQUE (delivery_request_id) WHERE status = 'active'`
   em `delivery_assignments`.
2. **RPC `claim_delivery()`** transacional: `SELECT … FOR UPDATE` na
   `delivery_requests`; valida status/offer; insere assignment; atualiza status;
   insere `delivery_event`; `COMMIT`. Retorna `won/lost`.
3. **Idempotência**: retries/webhooks duplicados batem na constraint/lock →
   retornam `already_assigned`.

Mesmo após o Bid Engine escolher o candidato, ele **não** é vencedor oficial até
`claim_delivery()` confirmar atomicamente.

## Consequências

- Provável por construção; testes de concorrência são **gate de produção** (Sessão 10).
- Dois n8n/instâncias tentando atribuir simultaneamente → um único vencedor.
- Estado final sempre consistente e auditável no banco.

## Referências

`ARCHITECTURE.md` seção 6, `BACKEND.md`, `docs/BID_ENGINE.md`, ADR-001, ADR-006.