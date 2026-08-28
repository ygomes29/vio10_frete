# docs/DATACRAZY_INTEGRATION.md — Integração DataCrazy / WhatsApp

> Documento de referência para as Sessões 15 e 16.

## O que é o DataCrazy

DataCrazy é um CRM brasileiro focado em automação de WhatsApp com "Crazy IA" —
agentes de IA configuráveis (prompt, base de conhecimento, restrições de assuntos,
transferência para humano) conectados à WhatsApp Cloud API oficial (ou Z-API /
Evolution API V2). Integra-se via webhooks (+500 plataformas).

Fontes: [WhatsApp Crazy IA](https://datacrazy.io/whatsapp-crazy-ia/),
[Guia do Agente de IA](https://help.datacrazy.io/pt-br/articles/10670800-guia-de-configuracao-do-agente-de-ia).

## Fronteira absoluta

> **DataCrazy / IA nunca escreve no banco.**

Fluxo permitido:

```
DataCrazy → n8n (quando há orquestração/temporização) → backend/API → banco
DataCrazy → backend/API → banco   (em chamadas apropriadas)
```

Fluxo **proibido**:

```
DataCrazy → SQL/banco diretamente
```

A IA **não** inventa preço, ETA, entregador ou status. Esses dados vêm do sistema.
A IA interpreta linguagem e chama o backend via webhook com payload estruturado.

## Papel da IA

### Agente de pedidos (empresa — Sessão 15)

Obter: origem, destino, destinatário, descrição do produto, veículo quando
necessário, urgência, observações. Se faltar dado obrigatório, **perguntar**.
Quando houver dados suficientes:

1. envia estrutura validada ao backend (via n8n ou direto);
2. backend cria `delivery_request`;
3. pricing calcula cotação;
4. agente comunica o preço;
5. empresa confirma;
6. backend autoriza início do dispatch.

A IA **não** altera o banco diretamente quando uma API/service existe. Usa
**schemas estruturados** para tools/actions (payload do webhook).

### Notificações de oportunidade (entregador — Sessão 16)

Enviar oferta ao entregador com apenas o necessário para decisão: região de coleta,
região de destino, distância estimada, veículo, valor oferecido, tempo para
responder. Ações: ACEITAR / FAZER LANCE / RECUSAR — via **link assinado + expirável**
que chama o backend. **Não** expor dados pessoais do cliente antes da atribuição;
após atribuir, liberar dados de execução.

## Invariantes

- Links de ação são **autenticados/assinados e expiráveis** (HMAC/JWT curto, escopo
  à offer/driver).
- Respostas chamam o **backend**, não alteram estado via DataCrazy.
- Duplicatas (clique duplicado, mensagem duplicada) → idempotência no backend.
- Oferta expirada / corrida já atribuída → resposta tratada pelo backend.

## Logs e erro

Logs suficientes para diagnóstico. Tratamento de erro determinístico. Sem secrets
expostos. `correlation_id` propagado entre DataCrazy → n8n → backend.

## Testes (Sessão 15/16)

- pedido normal; dado faltante (IA pergunta);
- confirmação de preço;
- aceitação normal; oferta expirada; corrida já atribuída;
- lance; recusa; ação duplicada;
- payload inválido rejeitado pelo backend.