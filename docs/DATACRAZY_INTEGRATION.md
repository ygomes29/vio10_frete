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

### Entrega do OTP ao recebedor (Sessões 15-16, ADR-017 D1/D6)

> **Especificado** na Sessão 12 (a RPC `generate_delivery_otp` que o backend consome está
> implementada e validada — 0028). **Implementação live deferida** para as Sessões 15-16
> (requer WhatsApp/DataCrazy provisionado). Não simulado (regra mestra).

**Objetivo:** entregar ao recebedor (`delivery_contact_phone`) o código de 6 dígitos que
verifica que ele recebeu a encomenda. O driver **não** vê o código — ele coleta o código do
recebedor no ato da entrega e o submete no POD.

- **Trigger:** ao entrar `in_transit` (ou ao atribuir a corrida — decisão de orquestração,
  Sessão 14), o backend chama `generate_delivery_otp(delivery_request_id, ttl_seconds?,
  max_attempts?, correlation_id)` (system-scoped, Service Role). A RPC retorna
  `(ok, reason, otp_code)` — o `otp_code` plaintext **só** ao backend; persiste só o hash
  salt+sha256 em `delivery_otps`.
- **Envio:** backend encaminha o código ao `delivery_contact_phone` via DataCrazy/WhatsApp
  (mensagem tipo "Seu código de entrega ViO10 é 123456. Informe ao entregador na entrega.").
  TTL default 900s; o recebedor tem 15 min para receber a encomenda e informar o código.
- **Coleta:** o driver pergunta o código ao recebedor no ato da entrega e o submete via
  `submit_proof_of_delivery(pod_type='delivery', p_otp_code=<código>)`. A RPC valida o
  hash contra `delivery_otps` (`for update`) e consome o OTP na mesma tx do insert do POD.
- **Falhas de OTP (tratamento):**
  - código errado → `otp_invalid` (`attempts++`); após `max_attempts` (default 5) →
    `otp_max_attempts` (locked). O driver pode pedir regeneração (backend chama
    `generate_delivery_otp` de novo — upsert reseta `attempts`/`consumed_at`/`expires_at`).
  - código expirado → `otp_expired`; regenerar.
  - OTP nunca gerado (backend não enviou) → `otp_not_generated` no submit; o driver usa
    foto-only (evidência sem verificação de recebedor) ou o backend regenera.
- **Foto-only (fallback):** se o recebedor não recebeu o código (sem WhatsApp, número
  errado), o driver pode submeter POD foto-only — aceito, mas **não verifica** o recebedor
  (evidência visual). Either-or preservado (D4).
- **Idempotência:** `generate_delivery_otp` é upsert em `delivery_otps` (`unique
  delivery_request_id`) — regenerações sobrescrevem. `submit_proof_of_delivery` com OTP
  match consome `consumed_at=now()` (1 uso); segundo submit bate `unique (delivery_request_id,
  pod_type)` → `pod_already_submitted`.
- **Invariantes específicos:**
  - O código plaintext **nunca** transita por DataCrazy/IA além do envio ao recebedor — a IA
    não "decide" o código, só o entrega como mensagem. O backend gera; a IA entrega.
  - O `delivery_contact_phone` é o alvo fixo da corrida (definido na criação, 0007); a IA
    não pode redirecionar o OTP a outro número.
  - Logs de OTP: `correlation_id` + `delivery_request_id` + `otp_generated` event (actor
    system); o plaintext **não** é logado (só o hash).

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