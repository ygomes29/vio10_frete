# ADR-010 — Ciclo de vida de identidade e autenticação (MVP)

- **Status**: Aprovado
- **Data**: 2026-08-28
- **Sessão**: 05

## Contexto

A Sessão 04 deixou pronto o modelo RBAC (ADR-009), grants least-privilege (0015), RPCs
`SECURITY DEFINER` (0016) e RLS policies (0017). Mas o **ciclo de vida de identidade**
ainda não existe:

- `profiles` (0004) tem `id references auth.users(id) on delete cascade`, mas **nenhum
  trigger** cria a linha de `profiles` quando um `auth.users` nasce (signup/convite). Sem
  o perfil, `user_platform_roles`, `organization_memberships` e `drivers` — que têm FK
  para `profiles(id)` — não podem ser criados: violação de FK no primeiro papel/membership.
  O comentário "0015 perfil via backend" deixava implícita uma decisão que nunca foi
  registrada.
- Não há tabela de **convites**: a "delegação" (admin convida operador; business_owner
  convida business_user; admin provisiona driver) foi listada em ADR-009 como
  "Sessão 05" sem modelo.
- Não há fluxo de **atribuição de papel** além de `service_role` escrever direto — não
  há contrato DB testável, nem defesa em profundidade (só o backend confia).
- Nenhum ADR registra as decisões de **método de auth**, **criação de perfil**,
  **JWT claims** e **política de sessão** — viola a regra mestra "não decidir arquitetura
  em conversa sem registro".

Sessão 05 é a **fundação backend/config de auth**. A UI de auth (`@supabase/ssr`,
cookie wiring, telas de login/registro por superfície) fica para as Fases 9-11
(Sessões 17-19), quando o app Next.js for scaffoldado. Aqui entregamos o **contrato DB
de identidade/convite** + **config Supabase Auth** + este ADR + testes + replay
from-scratch (hardening da cadeia 0001→0019).

## Decisões

### D1 — Método de autenticação: email + senha (baseline MVP)

MVP usa **email + senha** (Supabase Auth nativo, cookie-based server-side) para todas as
superfícies (admin, business, driver). `profiles.phone` existe como metadado, **não** é
identificador de auth.

- **Telefone/OTP e magic-link** ficam **adiados** para a fase de frontend (Sessões
  17-19), quando houver UI e caso real (drivers phone-first, integração WhatsApp). A
  camada DB de convites/papéis é idêntica nos três métodos, então adiar não gera retrabalho.
- `enable_phone = false` no `config.toml` por ora; `enable_email = true`.
- `password_min_length = 12` (alinha com a política de senha forte já exigida em
  `recreateVirtualMachine`; alinhado a `minimum_password_length` em `config.toml`).

### D2 — Criação de perfil: trigger `handle_new_user` (0018)

Um **trigger `SECURITY DEFINER` em `auth.users AFTER INSERT`** cria a linha em
`profiles(id = new.id, full_name/phone de new.raw_user_meta_data)`, com
`on conflict (id) do nothing`. É o padrão oficial Supabase.

- **Por que trigger (e não "backend cria perfil")**: as FKs de
  `user_platform_roles` / `organization_memberships` / `drivers` apontam para
  `profiles(id)`. Confiar no backend lembrar de criar o perfil em todo signup/convite é
  frágil — um esquecimento vira `foreign_key_violation` no primeiro papel atribuído. O
  trigger **garante** a consistência independentemente do caminho (signup direto, convite
  aceito, provisionamento admin). O perfil nasce vazio e é preenchido depois.
- **O que o trigger NÃO faz**: não atribui papel/membership/driver. Essas atribuições
  são feitas por `accept_invitation` (convite) ou RPCs admin DEFINER (0019) — **nunca**
  no trigger. Isso mantém o gatilho simples e a atribuição de papel como ato explícito
  autorizado.
- **Correção do comentário "0015 perfil via backend"**: refere-se a **role/membership**
  (metadados de authz, resolvidos server-side), **não** à existência do row de `profiles`
  (que agora nasce via trigger). O comentário de 0015 é atualizado nesta sessão.

### D3 — Modelo de convite: tabela `invitations` + accept autenticado (0019)

Tabela `invitations(email, role_type, organization_id?, invited_by_user_id, token,
status, expires_at, accepted_by_user_id?, accepted_at?, driver_meta?)` com RLS.

- **Fluxo**: inviter autorizado chama `create_invitation(...)` (RPC DEFINER) → gera
  `token`, insere `pending`, **não** cria `auth.users` (o signup via Supabase Auth Admin
  API é responsabilidade do backend, fora do escopo DB). O backend entrega o link
  (WhatsApp/email — DataCrazy/SMTP, na fase de integração). O convidado abre o link,
  **faz signup/login** (Supabase Auth) e chama `accept_invitation(token)` autenticado.
- **`anon` NÃO acessa**: o accept exige um usuário **autenticado** cujo email casa com
  `invitations.email`. A prova de propriedade do email vem do login (Supabase Auth
  confirmou o email / OTP / senha). Sem login, sem aceitar. Isso mantém `anon` sem grants
  (consistente com o MVP "sem superfície pública").
- `accept_invitation` aplica o papel **idempotentemente** (`on conflict do nothing` em
  `user_platform_roles` / `organization_memberships`; driver via insert em `drivers`
  com `on conflict (user_id) do nothing`). Aceitar 2x não duplica memberships e não
  reabre convite `accepted`. Respeita a regra de idempotência da regra mestra.
- **Validade**: `status = 'pending'` e `expires_at >= now()`. Expirado ou já accepted →
  `not_authorized`.

### D4 — Atribuição de papel: RPCs admin DEFINER (0019)

Provisionamento direto (sem convite) por RPCs `SECURITY DEFINER` com authz interna
(`auth.uid()`):

- `assign_platform_role(p_user_id, p_role)` — `super_admin`/`admin` apenas (platform
  role). Idempotente (upsert).
- `add_org_member(p_user_id, p_organization_id, p_role)` — `super_admin`/`admin` **ou**
  `business_owner` da própria org. Idempotente (`UNIQUE(user_id, organization_id)`).
- `create_driver(p_user_id, p_full_name, p_phone)` — `super_admin`/`admin` apenas. Insert em
  `drivers` (`account_status` default `pending`).

Esses RPCs seguem o **Modelo B** (Sessão 04): `SECURITY DEFINER` + checagem `auth.uid()`
interna; `authenticated` recebe `EXECUTE` mas nenhum DML direto em
`invitations`/`user_platform_roles`/`organization_memberships`/`drivers`. O direito de
AGIR (atribuir papel) fica imposto no banco, não só no serviço — defesa em profundidade.

#### D4.1 — Visibilidade vs. autoridade: `is_platform_admin()` ≠ `is_super_or_admin()`

Refinamento crítico descoberto na validação da Sessão 05. O ADR-009 dá a `operator`
**visibilidade** cross-tenant (despacho operacional); o helper `is_platform_admin()`
(0017) inclui `operator` (junto com `super_admin`/`admin`) e é usado nas **policies de
RLS de visibilidade** — correto. Mas **autoridade de mutação** (atribuir papel,
provisionar driver, cancelar convite alheio, adicionar membro via path platform) é
restrita a `super_admin`/`admin` (ADR-009 D7: operator **não** convida/atribui). Reusar
`is_platform_admin()` nessas RPCs seria **escalonamento de privilégio**: um `operator`
poderia atribuir papéis a terceiros.

Solução (0019): helper `is_super_or_admin()` (`super_admin`/`admin`, exclui `operator`)
usado nas **4 RPCs de mutação** (`assign_platform_role`, `create_driver`,
`cancel_invitation`, `add_org_member` path platform). A RLS de **visibilidade** de
`invitations` mantém `is_platform_admin()` (operator vê convites — leitura, baixo risco,
consistente com visibilidade platform-wide do ADR-009). Lição: visibilidade (V) e
autoridade de agir (C/X) são eixos distintos; um helper de RLS não deve ser reusado como
helper de authz de mutação sem confirmar a quem ele inclui.

### D5 — JWT: DB-lookup, **sem custom claims**

As policies de RLS (0017) e a authz dos RPCs resolvem o caller via `auth.uid()` + helpers
DB-lookup (`is_platform_admin()`, `my_org_ids()`, `my_driver_id()`). **Não** há custom
claims no JWT (sem `auth.hook.custom_access_token`).

- **Por que DB-lookup**: simplicidade — os helpers já existem e são testados (Sessão 04,
  21/21). Custom claims exigiria um hook que lê `user_platform_roles`/`organization_memberships`
  no issue do token e embute papéis no JWT; exigiria reemitir tokens a cada mudança de
  papel (atribuição/remoção) sob pena do JWT mentir; e duplicaria a fonte da verdade
  (banco E token). DB-lookup lê sempre o estado atual — o token nunca mente sobre papéis.
- **Trade-off aceito**: cada request com authz faz um SELECT a mais (helpers). No MVP
  (tráfego baixo, índices em `user_id`/`user_id,organization_id`) é desprezível. Se virar
  gargalo, custom claims com invalidação em mudança de papel é a evolução — registrada
  como "Fora do escopo".

### D6 — Política de sessão: cookie-based server-side (Supabase Auth padrão)

Sessões via cookies HTTP-only (Supabase Auth `@supabase/ssr`), refresh-token rotation
ativado (`enable_refresh_token_rotation = true`, já no `config.toml`). Os detalhes de
wiring de cookie (middleware Next.js, refresh server-side) ficam para a fase de frontend
(Sessões 17-19). Nada no banco depende disso.

### D7 — Matriz de quem convida quem (extende ADR-009)

| Convite para | Autorizado a convidar | Via |
|---|---|---|
| `super_admin`, `admin` | `super_admin` apenas | `create_invitation` (admin check) |
| `operator` | `super_admin`, `admin` | `create_invitation` |
| `driver` | `super_admin`, `admin` | `create_invitation` + `create_driver` |
| `business_owner` (nova org) | `super_admin` | `create_invitation` (org obrigatória) |
| `business_user` | `business_owner` da própria org; `super_admin`, `admin` | `create_invitation` (org = própria) |

**Quem NÃO convida**: `operator`, `business_user`, `driver`. Um driver jamais convida
outro; um business_user não delega; um operator não cria admin. Isso segue a hierarquia
do ADR-009 (platform > org; owner > user; admin > operator/driver).

## Consequências

- **0018** adiciona `handle_new_user` (trigger + função DEFINER). Garante FK de perfis.
- **0019** adiciona `invitations` + 6 RPCs DEFINER + RLS + grants. Fecha o fluxo de
  delegação/provisionamento de forma testável e idempotente.
- `config.toml` reflete D1 (email, senha forte 12, sem phone/anon).
- **Hardening**: o reset/replay from-scratch da cadeia 0001→0019 valida que toda a base
  nasce limpa em ordem (fecha o risco "BAIXO" do CODE_REVIEW da Sessão 04).
- **Defesa em profundidade mantida**: atribuição de papel é imposta no banco (RPC DEFINER)
  **e** no serviço (action authz antes da RPC) — igual ao padrão de corridas.
- `anon` permanece sem grants (accept exige login) — MVP sem superfície pública preservado.

## Fora do escopo (adiado)

- **UI de auth** (login/registro/aceitar-convite por superfície, cookie `@supabase/ssr`,
  refresh server-side) → Fases 9-11 (Sessões 17-19).
- **Telefone/OTP e magic-link** → quando houver caso real de driver phone-first.
- **Custom JWT claims** → só se DB-lookup virar gargalo medido.
- **Convite expiração por job** (varredura que marca `expired`) → MVP: `accept_invitation`
  rejeita `expires_at < now()`; limpeza assíncrona é otimização futura.
- **Rate limiting de convite/aceitar** → camada de serviço/API (Sessão 22, security review).
- **Auditoria de negação de acesso** → Sessão 22.
- **Revogação de papel** (`remove_platform_role`, `remove_org_member`,
  `deactivate_driver`) → Sessão 06+ quando surgir o fluxo de offboarding; o modelo já
  suporta (`drivers.account_status`, delete em memberships).

## Referências

`ADR-009` (matriz RBAC), `docs/SECURITY.md` (authz, idempotência), `BACKEND.md` (layering,
RPCs DEFINER), `ARCHITECTURE.md` §3.1 (user-scoped vs system-scoped), `0004_identity_tenancy.sql`
(profiles, user_platform_roles, organization_memberships), `0005_drivers.sql`,
`0015_grants_least_privilege.sql`, `0016_rpcs_security_definer.sql`, `0017_rls_policies.sql`.