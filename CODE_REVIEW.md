# CODE_REVIEW.md — Log de revisão do ViO10

> Registro contínuo de revisões, security review e decisões de qualidade.
> Sessões 22 e 28 populam este arquivo em profundidade. Por enquanto, apenas a
> fundação.

## Histórico

### Sessão 05 — Auth de usuários (Supabase Auth) + reset/replay from-scratch — PASS

- **ADR-010** escrito **antes** do código (auth method, profile, convites, JWT,
  session, matriz de quem convida quem) — regra mestra respeitada.
- **0018 `handle_new_user`** (`SECURITY DEFINER` on `auth.users` AFTER INSERT →
  `profiles`, `on conflict do nothing`): garante FK de `user_platform_roles`/
  `organization_memberships`/`drivers` → `profiles(id)`. O trigger **não** atribui
  papel (ato explícito via 0019). Sobrevive a `drop schema public cascade` (vive no
  schema `auth`); 0018 o recria idempotente no replay.
- **0019 `invitations` + 6 RPCs `SECURITY DEFINER`** (`create_invitation`,
  `accept_invitation`, `cancel_invitation`, `assign_platform_role`,
  `add_org_member`, `create_driver`) + helpers `my_email()`, `is_super_or_admin()`.
  Idempotentes (`on conflict do nothing`); authz por `auth.uid()`. Grants
  least-privilege (authenticated: EXECUTE + SELECT em `invitations` sob RLS, sem
  DML direto; anon: nada).
- **Bug real de escalonamento de privilégio encontrado e corrigido na validação**:
  os 4 RPCs de **mutação** usavam `is_platform_admin()` (que inclui `operator`,
  helper de *visibilidade* do ADR-009) → um `operator` podia atribuir papel a
  terceiros, criar driver, cancelar convite alheio. Corrigido: mutação usa
  `is_super_or_admin()` (`super_admin`/`admin`, exclui `operator`). RLS de
  *visibilidade* de `invitations` mantém `is_platform_admin()` (operator vê —
  leitura, ADR-009). Formalizado em ADR-010 D4.1. **Lição: V (visibilidade) ≠
  C/X (autoridade de agir); um helper de RLS não deve ser reusado como helper de
  authz de mutação sem confirmar a quem ele inclui.**
- **`test_vio10_auth_lifecycle.sql`** (34 asserções, begin/rollback): trigger,
  convites, authz do inviter, idempotência de accept, prova de email, expiração,
  driver via convite, RLS de invitations, anon bloqueado. **34/34 PASS (real)**.
- **`test_vio10_invariants.sql`**: `plan(12)`→`plan(13)` (rodava 13 asserções).
- **Reset/replay from-scratch (hardening final)**: `drop schema public cascade` +
  `delete from auth.users` + recriar `public` (via SQL + Management API; **não há**
  endpoint de reset a nível de projeto — só branch) + replay **0001→0019 em ordem**
  → todos aplicam limpo (19/19, sem MIGFAIL). Inventário: 26 tabelas (incl.
  `invitations`), RLS em todas (26/26), trigger `handle_new_user` presente,
  `anon`=0 grants.
- **Suítes re-executadas após reset from-scratch**: invariants **13/13**, rpcs
  **48/48**, authz **21/21**, auth_lifecycle **34/34** — todas PASS (não simulado).
- ~~**Risco em aberto (BAIXO): reset/replay from-scratch da cadeia 0001→0017 não
  executado**~~ → **FECHADO nesta sessão** (reset via SQL + replay 0001→0019
  limpo). Risco original da Sessão 04 resolvido.
- **Risco aberto (BAIXO)**: revogação de papel (`remove_platform_role`,
  `remove_org_member`, `deactivate_driver`) e limpeza assíncrona de convites
  expirados não existem — adiados (Sessão 06+ offboarding; ADR-010 "Fora do
  escopo"). `accept_invitation` rejeita `expires_at < now()`; limpeza é otimização.
- **Veredito**: GO para Sessão 06 (criação da corrida: empresas/entregadores/
  veículos + `delivery_request`).

### Sessão 04 — Auth/Grants/RLS/RBAC (Modelo B) — PASS

- **ADR-009** matriz RBAC escrita **antes** do código (grants/policies derivados da
  spec, não inventados — regra mestra respeitada). Driver corrigido: não está em
  `user_platform_roles` (identificado por linha em `drivers`).
- **Modelo B (decisão de usuário)**: RPCs user-facing `SECURITY DEFINER` + checagem
  interna de `auth.uid()`. **Reverte** INVOKER da Sessão 03. Descoberto na Sessão 04:
  INVOKER exigiria DML a `authenticated`, abrindo bypass da máquina de estados via
  PostgREST direto (`PATCH delivery_requests.status`). DEFINER + sem DML de domínio ao
  `authenticated` fecha o buraco. `auth.uid()` funciona sob DEFINER (lê JWT).
- **0016** aplicada (real): 4 RPCs confirmadas `SECURITY DEFINER`; grants PUBLIC
  revogados; EXECUTE reaplicado conforme 0015.
- **0017** aplicada (real): 25 policies + 5 helpers DEFINER (`is_platform_admin`,
  `my_driver_id`, `my_org_ids`, `is_org_member`, `can_view_delivery_request`).
- **`test_vio10_authz.sql` executado (real)**: **21/21 PASS** — cross-tenant (userA
  vê 0 de orgB, userB 0 de orgA), isolamento de driver (driverD só reqA/own offer/own
  row; driverD2 só reqB), papel sem policy vê 0 (userN), admin vê tudo (2/2/2), bypass
  UPDATE bloqueado (`insufficient_privilege`), `respond_to_offer` bloqueia driver
  errado (`not_authorized`) e permite o dono (`responded`).
- **System-path (auth.uid null) preservado**: smoke `claim_delivery` 4/4; R16
  cross-round PASS; **concorrência 2 claims paralelas → exatamente 1 `won=true`**
  (B won, A `not_searching_driver`), nunca ambos — partial unique index + `FOR UPDATE`
  intactos sob DEFINER.
- **Inventário final (real)**: 26 tabelas com RLS, 25 policies, 4 RPCs DEFINER, 5
  helpers, `authenticated` SELECT=20/INSERT=1/UPDATE=1/EXECUTE=8, `anon`=0.
- **Risco aberto (BAIXO)**: bypass via PostgREST **FECHADO** (Modelo B + grants sem
  DML de domínio ao authenticated). Invariante imutabilidade `delivery_events` confirmado
  novamente (bloqueou DELETE de cleanup, mesmo para owner).
- ~~**Risco em aberto (BAIXO)**: reset/replay from-scratch da cadeia 0001→0017 não
  executado~~ → **FECHADO na Sessão 05** (reset via SQL + Management API + replay
  0001→0019 limpo; ver Sessão 05).
- **Veredito**: GO para Sessão 05 (Auth de usuários Supabase + reset/replay from-scratch).

### Sessão 03.5 — Validação real da fundação (Gate B) — PASS
- **pgTAP executado (real)**: 12/12 invariantes PASS. Resolve o risco ALTO da Sessão 03
  (testes não executados). Executado server-side via Management API (sem Docker):
  runner próprio com temp table `_tap` + `num_failed()` + `begin/rollback` clean-slate.
- **RPCs executadas**: 48/48 PASS (4 RPCs × cenários de happy path, expiração,
  idempotência, transições inválidas, FK, reatribuição).
- **Concorrência `claim_delivery`**: 2 claims simultâneas → exatamente 1 `won=true`,
  nunca A=true E B=true. Garantia física (partial unique index) + lógica (`FOR UPDATE`).
- **`delivery_events` imutável**: trigger bloqueia UPDATE/DELETE (T12 PASS).
- **RLS default deny**: role autorizada sem policy vê 0 linhas (T10 PASS).
- **Grants audit (real)**: descoberto e corrigido gap — `revoke … from public` não
  removia auto-grants do Supabase a `anon`/`authenticated`/`service_role`. 0014
  endurecido: revoga de todos + `ALTER DEFAULT PRIVILEGES … REVOKE`. Após: 0
  privilégios para os três roles em 25 tabelas + 10 funções; owner retém.
- **R16 resolvido**: após atribuição oficial, TODAS as offers respondíveis da corrida
  (em qualquer rodada) viram `lost` — `claim_delivery` filtra por `delivery_request_id`.
  Teste cross-round real PASS. Resolve o risco MÉDIO da Sessão 03.
- **R17 documentado**: `external_reference` ≠ `idempotency_key`. Resolve o risco
  BAIXO da Sessão 03.
- **Correção arquitetural**: `service_role` user-scoped vs system-scoped (ver
  `ARCHITECTURE.md` §3.1).
- **PostGIS search_path**: migrations 0004/0005/0006/0007/0011 + test files recebem
  `set search_path to public, extensions;` (runner não inclui `extensions`).
- **Cadeia reproduzível**: reset + 0001→0014 do zero — 25 tabelas, 16 enums, 7 funcs,
  25 RLS, 14 migrations.
- **Veredito**: GO para Sessão 04 (Auth/Grants/RLS/RBAC).

### Sessão 03 — Banco (Gate B) — implementação
- Invariante crítica (atribuição única) protegida no banco: partial unique index +
  RPC `claim_delivery` com `FOR UPDATE`. Conforme ADR-007.
- RPCs em `SECURITY INVOKER` + `search_path` fixo; **nenhum** `SECURITY DEFINER` para
  bypassar RLS (regra respeitada).
- RLS default deny desde a primeira migration (sem policies amplas) — Sessão 04 formaliza.
- `delivery_events` imutável por trigger.
- ~~**Risco aberto (ALTO)**: testes pgTAP não executados~~ → **RESOLVIDO na Sessão 03.5**.
- ~~**Risco (MÉDIO)**: offers de rounds anteriores~~ → **RESOLVIDO (R16) na Sessão 03.5**.
- ~~**Risco (BAIXO)**: `external_reference` unique com NULLs~~ → **documentado (R17) na
  Sessão 03.5**; comportamento SQL intencional, idempotência via `integration_events`.

### Sessão 01 — Diagnóstico
- Repositório greenfield confirmado. Nenhuma stack herdada.
- Risco crítico identificado: atribuição dupla de corrida → mitigado por
  constraint + RPC transacional (formalizado na Sessão 02 / ADR-007).
- Risco crítico: n8n como fonte da verdade → mitigado por fronteiras de escrita
  (ADR-004).

### Sessão 02 — Documentação
- Decisões arquiteturais formalizadas em ADRs (ADR-001 a ADR-008).
- Correção crítica aplicada: semântica de ACEITAR no bid engine (não é vitória
  imediata). Registrada em ADR-006 e `docs/BID_ENGINE.md`.

## Achados abertos

- **Revogação de papel / offboarding** (BAIXO): `remove_platform_role`,
  `remove_org_member`, `deactivate_driver` e limpeza assíncrona de convites
  expirados não existem (Sessão 05 entregou atribuição, não revogação). Adiados para
  Sessão 06+. `accept_invitation` já rejeita `expires_at < now()`; o modelo
  (`drivers.account_status`, delete em memberships) suporta revogação futura.

## Classificação de severidade (a usar nas revisões)

- **P0** — bloqueia produção
- **P1** — risco alto
- **P2** — importante
- **P3** — melhoria

## Tópicos a cobrir na Sessão 22 (security review)

Autenticação, autorização, RLS, APIs, server actions, webhooks, uploads, storage,
links de aceitação, secrets, env vars, DataCrazy, n8n, banco, logs, PII, endpoints
administrativos, rate limiting, abuso, replay, IDOR, injection, concorrência.

## Notas de segurança conhecidas já registradas

- **Next.js 16.3.3** patch de segurança (25/ago/2026): corrige RCE em otimização de
  imagens AVIF (GHSA-2xp9-vwfh-vxw4) e RCE em Windows (GHSA-p293-qw3h-jr36). O RCE de
  Windows não nos atinge (deploy em Linux/Vercel). AVIF é desabilitado na patch.
  Fonte: [August 2026 Security Release](https://nextjs.org/blog/august-2026-security-release).