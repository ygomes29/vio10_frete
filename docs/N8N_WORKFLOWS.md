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

## Workflow #13 — entrega concluída (design Sessão 12, ADR-017 D6; implementação Sessão 14)

> **Especificado** nesta sessão (DB/RPC que consome está implementado e validado —
> `confirm_delivery` 0028). **Implementação live deferida para a Sessão 14** (requer n8n
> provisionado). Não simulado (regra mestra).

**Objetivo:** auto-confirmar a entrega quando o driver submete o POD de delivery, sem que o
driver ou o frontend marquem `delivered`. Honra o two-phase POD (Sessão 11/12):
**submeter POD ≠ entregue** — o sistema confirma.

- **Trigger:** evento `pod_submitted` (Realtime sobre `delivery_events` onde
  `event_type='pod_submitted' and metadata->>'pod_type'='delivery'`, ou webhook do Route
  Handler de submit). Idempotente por `external_event_id`/`idempotency_key`.
- **Input:** `delivery_request_id`, `pod_id`, `correlation_id`.
- **Validações:** delivery em `in_transit` (senão ignora/sai — já foi confirmada ou
  cancelada); POD delivery existe e não foi já confirmado (idempotência — se já `delivered`,
  no-op).
- **Operação:** chama Route Handler `POST /api/internal/deliveries/{id}/confirm`
  (system-scoped, Service Role key) com `{geo_tolerance_m?, correlation_id}`. O Route
  Handler chama `confirm_delivery(p_delivery_request_id, p_geo_tolerance_m, p_correlation_id)`.
- **Resultado esperado:** `confirm_delivery` valida POD delivery existe →
  `transition_delivery('delivered')` re-valida POD gate + geo gate → transita
  `in_transit → delivered`. Retorna `('delivered', pod_id)` ou um reason
  (`pod_required`/`pod_geolocation_out_of_range`/outro).
- **Tratamento de reason de falha:**
  - `pod_geolocation_out_of_range` → notifica o driver (via workflow #12 notificações) que o
    POD está fora da tolerância e ele deve re-submeter ou contatar suporte; **não** força
    `delivered`. Orquestrador decide (reabrir janela de re-submissão ou escalar para admin).
  - outros reasons → loga + escala (workflow #14 falhas).
- **Eventos gerados:** `delivered` (pela `transition_delivery`), com `metadata.pod_id` e
  `metadata.geo_tolerance_m`.
- **Retries:** exponenciais com backoff; dead-letter após N (workflow #15). Idempotência
  garantida por `correlation_id` + estado da corrida (segundo trigger encontra `delivered` →
  no-op).
- **Geolocalização:** o `geo_tolerance_m` (default 200m se omitido) é repassado ao metadata
  da transição; o gate de geo (D2) compara `location_point` do POD ao `delivery_point`. POD
  sem location → skip do gate (MVP).
- **Pré-requisito de OTP:** o workflow **não** valida o OTP — isso já aconteceu em
  `submit_proof_of_delivery` (D1) antes de `pod_submitted` ser emitido. Se o OTP falhou, o
  submit retornou erro e `pod_submitted` **não** foi emitido. O workflow só vê submits
  bem-sucedidos.

**Dependência externa:** o envio do OTP ao recebedor (workflow separado, via
WhatsApp/DataCrazy — ver `docs/DATACRAZY_INTEGRATION.md` seção receiver-OTP, Sessões 15-16)
ocorre **antes** do submit, idealmente ao entrar `in_transit`. Sem OTP entregue ao
recebedor, o driver não tem como submeter `otp_code` válido (mas foto-only ainda funciona —
evidência sem verificação de recebedor).

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