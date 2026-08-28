# docs/SECURITY.md — Segurança do ViO10

> Documento de referência. Security review pesado na Sessão 22; aqui ficam os
> princípios e regras desde o início.

## Princípios

1. **Defesa em profundidade**: RLS no banco + autorização na camada de serviço.
   Mesmo que a API falhe em checar, o banco bloqueia cross-tenant.
2. **Negar por padrão**: acesso só quando explicitamente autorizado por papel +
   tenant.
3. **Banco é a autoridade final** para atomicidade e isolamento.
4. **Sem segredo no cliente**: chaves de serviços externos só no backend/env.
5. **Idempotência** em toda mutação sensível.
6. **Auditoria**: toda alteração relevante em corrida gera `delivery_event`.

## Papéis (RBAC)

`super_admin`, `admin`, `operator`, `business_owner`, `business_user`, `driver`.

Cada papel tem definido o que pode: visualizar, criar, alterar, cancelar,
atribuir, consultar valores, acessar dados de **outras** organizações.

### Isolamento multiempresa

- **Um estabelecimento não acessa corridas/outro estabelecimento.**
- **Um entregador não altera dados de outro entregador.**
- Só funções autorizadas executam operações administrativas.

Implementação: `organization_id` em toda tabela de domínio + **RLS** + autorização
no serviço. Testado explicitamente (tentativas de acesso indevido) na Sessão 04/22.

## Auth

- **Supabase Auth** (server-side, cookie-based) para sessão.
- Frontend recebe só dados autorizados; tokens/cookies gerenciados pelo backend.

### Contextos de execução — `service_role` user-scoped vs system-scoped

Dois contextos distintos (ver `ARCHITECTURE.md` §3.1):

- **User-scoped** — backend executa **em nome de um usuário autenticado** (role
  `authenticated`, JWT do usuário). **RLS aplica** e filtra por `organization_id`/driver.
  Usado para toda ação originada por um usuário (motorista aceita offer, business cria
  corrida, admin consulta). O backend **não** troca para `service_role` aqui para furar
  RLS — isso seria buraco de autorização.
- **System-scoped** — backend executa **como a própria plataforma** (role `service_role`,
  bypass de RLS via `rolbypassrls`). Usado para lógica de sistema confiável: dispatch
  engine, scoring, `claim_delivery`, expiração scheduled, transições de sistema,
  eventos de auditoria do sistema.

Regras:

1. **`service_role` nunca vaza** para n8n, DataCrazy, IA ou qualquer integrador externo.
   Eles chamam endpoints do backend; o backend decide o contexto por operação.
2. **RPCs são `SECURITY INVOKER`** (não `DEFINER`) — herdam RLS de quem chama. Chamada
   user-scoped → RLS aplica; chamada system-scoped → bypass. Sem atalho `DEFINER`.
3. **service_role tem grants default-deny** desde a Sessão 03.5 (0014): nenhum role
   não-owner tem privilégios em `public` até grants explícitos (Sessão 04). O backend
   system-scoped recebe grants **por função** (least-privilege), não "tudo".
4. **Promoção proibida**: uma ação iniciada por usuário roda user-scoped. O backend não
   a "promove" a system-scoped para contornar RLS. Se o usuário não teria direito via
   RLS, o backend também não concede.

## Idempotência

- `idempotency_key` em endpoints mutantes; `external_event_id` por evento.
- `integration_events(idempotency_key, source, external_event_id)` UNIQUE por origem.
- `webhook_events(source, external_id)` UNIQUE → dedup de webhooks.
- Aplica-se a: criação de pedido, confirmação de cotação, respostas a ofertas,
  bids, claim, transições, webhooks, notificações, pagamentos futuros.
- **Retries são parte normal da arquitetura.**

### R17 — `external_reference` ≠ `idempotency_key` (conceitos distintos)

Estes dois campos **não são a mesma coisa** e vivem em tabelas diferentes. Misturá-los
quebra a semântica de idempotência:

- **`idempotency_key`** (em `integration_events`, `bids`, `notifications`): chave de
  idempotência **da operação**. Garante que um **retry** da mesma chamada (mesma
  chave) não duplique efeito. Domínio do **backend/sistema** que executa a operação.
  `UNIQUE` global (ou por `source`) → segundo insert com a mesma chave vira replay e
  retorna o resultado já existente (não erro, não duplicação).
- **`external_reference`** (em `delivery_requests`): identificador **do registro no
  sistema de origem externa** (ex.: o pedido nº 1234 no ERP da empresa). É o vínculo
  do mundo externo com a corrida ViO10 — **não** é chave de retry. `UNIQUE` por
  `organization_id` → uma mesma organização não cria duas corridas para o mesmo
  `external_reference`. Pode ser `NULL` (corridas criadas direto no ViO10).
- **`external_event_id`** (em `integration_events`, `webhook_events.external_id`):
  id do **evento** recebido do emissor externo — dedup de **webhooks/eventos
  inbound** (o emissor reenvia o mesmo evento; o ViO10 não reprocessa).

Regra prática:

| Quero evitar... | Uso |
|---|---|
| Retry duplicando efeito de uma operação | `idempotency_key` |
| Duas corridas para o mesmo pedido externo | `delivery_requests.external_reference` (`UNIQUE` por org) |
| Reprocessar o mesmo webhook/evento inbound | `external_event_id` / `webhook_events.external_id` |

Quando `external_reference` é `NULL`, a idempotência da criação da corrida fica por
conta do `idempotency_key` em `integration_events` (camada de integração), não da
tabela de domínio.

## Links de ação (ofertas)

- Assinados (HMAC/JWT curto) e **expiráveis**.
- Escopo limitado à offer/driver específicos.
- Replay/forja → rejeitado.
- IDOR protegido: nenhum recurso acessível por ID adivinhável sem autorização.

## Concorrência / atomicidade

- Atribuição de corrida: constraint parcial `UNIQUE (delivery_request_id) WHERE
  status='active'` + RPC `claim_delivery()` com `FOR UPDATE`.
- Transições de estado: RPC `transition_delivery()` transacional.
- Cancelar vs atribuir simultâneos → resolvido pelo lock na `delivery_requests`.

## Storage / uploads (prova de entrega)

- **Supabase Storage** com **policies privadas**.
- Uploads autorizados e validados (tipo/tamanho). Nada de dados desnecessários.
- URLs assinadas/efêmeras para acesso.

## Secrets / env

- Nada de secrets no frontend nem no git.
- Variáveis de ambiente no backend; nunca expostas ao cliente.
- Webhooks recebidos validam assinatura do emissor quando aplicável.

## Observabilidade vs PII

- Logs carregam `correlation_id`, contexto operacional, resultado, erro.
- **PII mínima** em logs. Localização do entregador com TTL/consentimento; coleta
  só em corrida ativa ou quando autorizado.
- Documentar retention quando aplicável.

## Rate limiting / abuso

- Endpoints externos (webhooks, APIs públicas) com rate limiting.
- Proteção contra abuso de lances (limite por rodada por entregador, configurável).
- Proteção contra replay.

## Notas de segurança externas já registradas

- **Next.js 16.3.3** (25/ago/2026): corrige RCE em otimização AVIF
  (GHSA-2xp9-vwfh-vxw4) e RCE em Windows (GHSA-p293-qw3h-jr36 — não nos atinge,
  deploy Linux/Vercel). AVIF desabilitado na patch.
  Fonte: [August 2026 Security Release](https://nextjs.org/blog/august-2026-security-release).

## Tópicos para a Sessão 22 (auditoria)

Autenticação, autorização, RLS, APIs, server actions, webhooks, uploads, storage,
links de aceitação, secrets, env vars, DataCrazy, n8n, banco, logs, PII, endpoints
administrativos, rate limiting, abuso, replay, IDOR, injection, concorrência.
Classificação: CRÍTICO / ALTO / MÉDIO / BAIXO.