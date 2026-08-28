# CODE_REVIEW.md — Log de revisão do ViO10

> Registro contínuo de revisões, security review e decisões de qualidade.
> Sessões 22 e 28 populam este arquivo em profundidade. Por enquanto, apenas a
> fundação.

## Histórico

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

(nenhum — código de negócio ainda não existe)

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