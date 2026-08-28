# ADR-004 — n8n somente como orquestrador

- **Status**: Aprovado
- **Data**: 2026-08-27
- **Sessão**: 02

## Contexto

n8n é poderoso para eventos, timers, retries e integrações. Mas se virar fonte de
verdade, o estado do sistema fica opaco e sujeito a drift e duplicação.

## Decisão

**n8n é orquestrador, não fonte da verdade.** Ele recebe eventos, coordena
processos, dispara mensagens, chama APIs, controla timers, faz integrações — mas:

- **não** escreve estado crítico no banco diretamente;
- chama **Route Handlers** do backend (nunca Server Actions internas);
- o backend responde se a operação venceu/perdeu;
- webhooks/eventos são idempotentes.

## Consequências

- n8n nunca decide sozinho que uma corrida foi atribuída; solicita ao backend.
- Retries do n8n são seguros (idempotência no backend).
- Estado oficial é sempre consultável no banco, não na memória do n8n.

## Referências

`docs/N8N_WORKFLOWS.md`, ADR-001, ADR-007.