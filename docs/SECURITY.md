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
2. **RPCs user-facing são `SECURITY DEFINER` com checagem interna de `auth.uid()`**
   (Modelo B, Sessão 04 — reverte o INVOKER da Sessão 03; ver ADR-009 e
   `0016_rpcs_security_definer.sql`). A RPC roda como owner (bypassa RLS) e valida
   posse do caller internamente: `auth.uid() IS NULL` → system-scoped, permitido;
   `auth.uid() IS NOT NULL` → user-scoped, valida `drivers.user_id`, membership da org
   ou `user_platform_roles`. **Motivo:** com INVOKER + grants de DML a `authenticated`,
   um motorista logado poderia `PATCH delivery_requests.status` via PostgREST direto,
   furando a máquina de estados. Com DEFINER + **sem** DML de domínio a `authenticated`,
   a única mutação user-facing é a RPC, que faz a checagem. `auth.uid()` funciona sob
   DEFINER (lê o JWT, não o role do DB).
3. **Grants least-privilege** desde a Sessão 04 (`0014` default-deny total + `0015`
   least-privilege): `service_role` DML em tudo + EXECUTE nas 4 RPCs; `authenticated`
   SELECT em 20 tabelas (sob RLS `0017`) + EXECUTE nas 3 RPCs user-facing +
   INSERT/UPDATE só em `driver_locations`; `anon` nada. Mutação de domínio user-facing
   nunca por DML direto — só via RPC.
4. **Promoção proibida**: uma ação iniciada por usuário roda user-scoped. O backend não
   a "promove" a system-scoped para contornar RLS. Se o usuário não teria direito via
   RLS, o backend também não concede.
5. **RPCs system-only** (`create_quote` Sessão 07 ADR-012 D1; `open_dispatch_round`
   Sessão 08 ADR-013 D2): RPCs que **não aceitam caller autenticado de forma alguma** —
   `auth.uid() IS NOT NULL` → `not_authorized`. `revoke all from public` + `grant execute
   to service_role` **somente**: `authenticated` **nem EXECUTE** recebe (defesa em
   profundidade — bloqueio no nível de privilégio antes da checagem interna de
   `auth.uid()`); `anon`: nada. **Trust boundary dos insumos de pricing** (`create_quote`):
   distância/duração são do provider de rota (plataforma, Sessão 20), não do business —
   um business passando `p_distance_meters` forjaria distância pequena → preço baixo.
   **Trust boundary dos insumos de dispatch** (`open_dispatch_round`): raio/max_candidates/
   driver_offer/janela são do orquestrador (backend), não do business — um business
   passando `p_search_radius_m`/`p_driver_offer_cents` forjaria a busca/oferta. O dashboard
   "solicitar cotação"/"abrir despacho" chama um Route Handler do backend, que chama a RPC
   system-scoped (Sessão 18). Distinto de `create_delivery_request`/`confirm_quote`
   (aceitam membro de org): os endereços da corrida são do business; a distância e os
   insumos de dispatch são da plataforma.

### Auth de usuários — identidade, convite e atribuição de papel (Sessão 05, ADR-010)

- **Método de auth MVP**: email + senha (Supabase Auth, cookie-based server-side).
  `enable_anonymous_sign_ins=false`; senha forte (`minimum_password_length=12`,
  `lower_upper_letters_digits_symbols` em `config.toml`). Telefone/OTP e magic-link
  **adiados** para a fase de frontend (Sessões 17-19); a camada DB de convites/papéis
  é idêntica nos três métodos, então adiar não gera retrabalho. UI de auth (`@supabase/ssr`,
  cookie wiring, telas por superfície) fica para as Sessões 17-19; nada no banco depende.
- **Criação de perfil via trigger** (`handle_new_user`, 0018): `SECURITY DEFINER` on
  `auth.users` AFTER INSERT → `profiles` (`on conflict do nothing`). **Garante a FK**
  de `user_platform_roles`/`organization_memberships`/`drivers` → `profiles(id)` em
  todo caminho (signup, convite aceito, provisionamento admin). O trigger **não**
  atribui papel — ato explícito via 0019.
- **Convite exige login (`anon` não acessa)**: `accept_invitation(p_token)` só roda
  para um caller **autenticado** cujo email casa com `invitations.email`. A prova de
  propriedade do email vem do login (Supabase Auth confirmou). Sem login, sem aceitar.
  `anon` não recebe grants em `invitations` nem `EXECUTE` em `accept_invitation` —
  bloqueado no nível de privilégio (defesa em profundidade **antes** da checagem
  interna de `auth.uid()`).
- **Idempotência de aceitar**: `accept_invitation` aplica o papel com
  `on conflict do nothing` (`user_platform_roles`/`organization_memberships`; driver
  via insert em `drivers` com `on conflict (user_id) do nothing`). Aceitar 2x →
  `already_accepted`, **não duplica** memberships nem reabre o convite. Respeita a
  regra de idempotência da regra mestra (§ Idempotência abaixo).
- **Visibilidade ≠ autoridade (ADR-010 D4.1)**: a RLS de *visibilidade* de
  `invitations` usa `is_platform_admin()` (inclui `operator` — despacho cross-tenant,
  ADR-009). As 4 RPCs de **mutação** (`assign_platform_role`, `create_driver`,
  `cancel_invitation`, `add_org_member` path platform) usam `is_super_or_admin()`
  (`super_admin`/`admin`, **exclui** `operator`) — o operator **não** convida/atribui
  (ADR-010 D7). Reusar `is_platform_admin()` em mutação seria escalonamento de
  privilégio (um operator atribuiria papéis a terceiros). **Lição**: V (visibilidade)
  e C/X (autoridade de agir) são eixos distintos; um helper de RLS não deve ser
  reusado como helper de authz de mutação sem confirmar a quem ele inclui.
- **JWT DB-lookup, sem custom claims**: as policies de RLS e a authz dos RPCs resolvem
  o caller via `auth.uid()` + helpers DB-lookup (`is_platform_admin`, `my_org_ids`,
  `my_driver_id`, `my_email`, `is_super_or_admin`). Nada em `auth.hook.custom_access_token`.
  O token nunca mente sobre papéis (lê sempre o estado atual do banco); custom claims
  exigiria reemitir tokens a cada mudança de papel.

### Matriz de autoridade de gestão (Sessão 06, ADR-011 D4)

Estende a matriz RBAC do ADR-009 para a **criação/mutation** de entidades e da corrida.
Todas via RPC `SECURITY DEFINER` (Modelo B) — `authenticated` **sem DML** nessas
tabelas; a única mutação user-facing é a RPC, que checa `auth.uid()` internamente.
`anon`: nada. Visibilidade (SELECT) já coberta pela RLS de 0017.

| RPC | Autorizado (user path) | System path |
|---|---|---|
| `create_organization` | `is_super_or_admin()` (provisionamento de tenant) | permitido (backend) |
| `create_business` | `is_super_or_admin()` **ou** `business_owner` da própria org | permitido |
| `create_business_location` | `business_owner` da org do business **ou** `is_super_or_admin()` | permitido |
| `create_vehicle` | **driver self** (`drivers.user_id = auth.uid()` de `p_driver_id`) **ou** `is_super_or_admin()` | permitido |
| `set_current_vehicle` | driver dono do veículo **ou** `is_super_or_admin()` | permitido |
| `update_driver_status` | `is_super_or_admin()` apenas | **negado** |
| `create_delivery_request` | membro da org (`organization_memberships`) **ou** `is_platform_admin()` (admin/operator) | **permitido** (api/integration/whatsapp) |
| `create_quote` | **negado** (system-only — `auth.uid() IS NOT NULL` → `not_authorized`; `authenticated` sem EXECUTE) | **permitido** (backend cota `draft→quoted`; insumos de rota da plataforma) |
| `confirm_quote` | membro da org **ou** `is_platform_admin()` (admin/operator) | **permitido** (backend confirma `quoted→searching_driver`; valida quote pendente não expirada) |
| `open_dispatch_round` | **negado** (system-only — `auth.uid() IS NOT NULL` → `not_authorized`; `authenticated` sem EXECUTE) | **permitido** (backend abre rodada de dispatch; insumos de raio/oferta do orquestrador) |

Notas:
- **`create_organization` = super/admin apenas**: criar tenant é ato de plataforma. O
  primeiro `business_owner` entra via convite (0019) depois da org existir.
- **`create_vehicle` = driver self ou admin**: veículos são **driver-owned**
  (`vehicles.driver_id` NOT NULL; drivers platform-scoped). O entregador registra a
  própria moto (PPA na Sessão 17); admin pode provisionar. `create_driver` (0019) é
  admin-only (cria identidade); veículo é posse do driver.
- **`update_driver_status` = super/admin, sem system**: ativa/suspende/bloqueia é
  mutação de **identidade** — alinhado a 0019 (mutação de identidade exige admin
  autenticado, sem system). Fecha o lado driver do risco offboarding (parcialmente:
  `account_status` cobre ativo/suspenso/bloqueado; `remove_platform_role`/
  `remove_org_member` ainda deferidos).
- **`create_delivery_request` aceita system path**: origens `api`/`integration`/
  `whatsapp` (Sessões 13/15–16) criam corrida via backend system-scoped. Dashboard
  (business/admin/operator) usa user path. `operator` (em `is_platform_admin()`) pode
  criar — despacho operacional pode abrir corrida manualmente.
- **`external_reference` = dedup de criação** (não retry): `on conflict
  (organization_id, external_reference) do nothing` → `already_exists` idempotente.
  Distinto de `idempotency_key` (ver **R17** abaixo). Retries de operação ficam com
  `integration_events.idempotency_key` (Sessão 13).
- **Ator capturado por `auth.uid()`** (D6): system → `'system'`; platform admin →
  `'admin'`; membro de org → `'business'`. O `actor_type` nunca vem de parâmetro
  (alinha com `transition_delivery`).

### Matriz de autoridade de dispatch (Sessão 08, ADR-013)

Estende a matriz para o **motor de despacho**. `confirm_quote` é user-facing (membro da
org/operator/admin confirmam a cotação); `open_dispatch_round` é system-only (o
orquestrador/backend abre rodadas — insumos de raio/oferta não vêm do business). Ambas via
RPC `SECURITY DEFINER` (Modelo B); `authenticated` **sem DML** em `dispatch_rounds`/
`delivery_offers` — só EXECUTE em `confirm_quote` + SELECT sob RLS (0017); `anon`: nada.

- **`confirm_quote` aceita user path**: business_owner/business_user (membro da org),
  operator/admin (`is_platform_admin()`) e system (backend). **Transition-first**
  (`quoted→searching_driver` via `transition_delivery`) **antes** de marcar a quote
  `confirmed` — se a transição falhar (race → `wrong_state`), retorna sem marcar (sem
  quote confirmed órfã). Idempotência por estado: re-confirmar → `wrong_state`.
- **`open_dispatch_round` system-only, segundo após `create_quote`**: `authenticated`
  **nem EXECUTE** recebe (defesa em profundidade). **Trust boundary de dispatch:** raio,
  max_candidates, `driver_offer_cents`, janela, `max_location_age_seconds` são insumos do
  orquestrador (backend), não do business — um business passando esses params forjaria a
  busca/oferta. O backend lê config própria (tabela `dispatch_config` adiada). Raio
  progressivo = orquestrador chama N vezes com raios crescentes (D5); `round_number`
  monotônico; guard `round_already_open` (fechar rodada é Sessão 09). Cria a rodada
  **mesmo com 0 candidatos** (audit snapshot). Eligibility MVP (D3): `active`+`available`
  +veículo compatível+sem assignment ativa+localização fresca+`ST_DWithin` no raio
  (proximidade operacional, não cobrança). **Não muta `current_availability_status`**
  (`offered` reservado); guard contra dupla offer na rodada = UK `(round_id, driver_id)`.
- **Sem novos grants de DML a `authenticated`; sem tabela nova** (D8): `dispatch_rounds`/
  `delivery_offers` já têm RLS SELECT (0017) + `service_role` DML (0015). Único grant
  system-only novo: `execute on open_dispatch_round to service_role`.

## Idempotência

- `idempotency_key` em endpoints mutantes; `external_event_id` por evento.
- `integration_events(idempotency_key, source, external_event_id)` UNIQUE por origem.
- `webhook_events(source, external_id)` UNIQUE → dedup de webhooks.
- Aplica-se a: criação de pedido, confirmação de cotação, respostas a ofertas,
  bids, claim, transições, webhooks, notificações, pagamentos futuros, e
  **aceitar convite** (`accept_invitation` idempotente; ver ADR-010 D3).
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