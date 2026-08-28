# ADR-001 — Banco como fonte da verdade

- **Status**: Aprovado
- **Data**: 2026-08-27
- **Sessão**: 02

## Contexto

O ViO10 tem estados operacionais críticos (atribuição de corrida, ciclo de
entrega, financeiro) que não podem depender de timing de orquestradores externos
(n8n) nem de IA. Histórias de corridas com dois "vencedores" ou estado inconsistente
são inaceitáveis.

## Decisão

**PostgreSQL (via Supabase) é a fonte oficial da verdade** para todo estado
operacional e financeiro. A atomicidade e o isolamento são garantidos no banco:
constraints, locks e funções RPC transacionais.

## Consequências

- n8n, DataCrazy e frontend **não** escrevem estado crítico diretamente.
- Operações atômicas viram funções RPC (`claim_delivery`, `transition_delivery`).
- RLS e constraints são a garantia final, independente de camadas acima.
- O banco pode ser auditado como a realidade do negócio.

## Referências

`ARCHITECTURE.md`, `BACKEND.md`, ADR-004, ADR-007.