# docs/N8N_WORKFLOWS.md — Workflows n8n

> Placeholder da Sessão 02. A **arquitetura** dos workflows é desenhada na Sessão 13
> e **implementada** na Sessão 14. Este arquivo já fixa as **regras obrigatórias**
> que qualquer workflow deve obedecer.

## Regra obrigatória

> **n8n nunca decide sozinho que uma corrida foi atribuída.** Ele solicita a operação
> ao backend. O backend responde se a atribuição venceu ou perdeu.

- n8n é **orquestrador**, não fonte da verdade.
- n8n **não** escreve estado no banco diretamente; chama Route Handlers do backend.
- n8n **não** depende de Server Actions internas.
- Webhooks e eventos são **idempotentes** (`idempotency_key`, `external_event_id`).
- Workflows separados, observáveis, versionáveis — **não** monolíticos.

## Workflows previstos (a detalhar na Sessão 13)

1. nova solicitação recebida
2. enriquecimento/geocodificação
3. cotação
4. início de dispatch
5. abertura de rodada
6. envio de ofertas
7. recebimento de respostas
8. timeout da rodada
9. nova rodada
10. atribuição confirmada
11. atualizações da corrida
12. notificações
13. entrega concluída
14. falhas
15. retry/dead-letter
16. webhooks DataCrazy

## Para cada workflow (a definir na Sessão 13)

- trigger;
- input;
- validações;
- operações;
- chamadas ao backend;
- eventos gerados;
- retries;
- idempotency key;
- tratamento de erro;
- logs.

## Caminho feliz (a construir primeiro na Sessão 14)

```
delivery.created → pricing → dispatch → offers → selection → assignment → notifications
```

Depois: timeout, retry, rejeições, erros, indisponibilidade, reatribuição.

## Logging

Cada integração tem logging suficiente para diagnóstico. **Nunca** exponha secrets
nos logs. Eventos críticos carregam `correlation_id`, `organization_id`,
`delivery_request_id`, origem, resultado.

## Registro final (Sessão 14)

Ao concluir, documentar aqui: ID/nome/função de cada workflow.