# ADR-009 — Matriz RBAC (papel × recurso × ação) — escopo MVP

- **Status**: Aprovado
- **Data**: 2026-08-28
- **Sessão**: 04

## Contexto

A Sessão 03.5 deixou o banco com RLS e grants em **default-deny total** (0014). A
Sessão 04 precisa substituir esse default-deny por **grants least-privilege** e
**RLS policies** — mas `docs/SECURITY.md` promete uma matriz de permissões por papel que
**nunca foi escrita**. Sem a matriz, grants/policies virariam permissões inventadas no
código, violando a regra mestra ("IA não inventa; backend decide a partir de spec").

O modelo de papéis já está decidido (0004):
- **Platform-scoped** (`user_platform_roles`, 1:1, sem `organization_id`):
  `super_admin`, `admin`, `operator`. (O enum `platform_role` é exatamente estes três.)
- **Driver** é platform-scoped (sem `organization_id`) mas **não** vive em
  `user_platform_roles` — é identificado pela linha em `drivers` (`user_id = auth.uid()`),
  resolvido por `my_driver_id()`. Logo "ser motorista" = ter linha em `drivers`.
- **Org-scoped** (`organization_memberships`, N:1, com `organization_id`):
  `business_owner`, `business_user`.

O MVP é single-tenant em Congonhas (`organization → business → business_location`
normalmente 1:1:1). A matriz precisa cobrir só o fluxo MVP; granularidade avançada é
adiada (ver "Fora do escopo").

## Decisão

Dois eixos ortogonais definem cada permissão: **papel** (quem) e **escopo** (quais
linhas). A **visibilidade** é imposta pela RLS (row-level); o **direito de agir** é
imposto pela camada de serviço (action-level), validado antes de chamar a RPC. RLS e
service authz são defesa em profundidade — nunca só um dos dois.

### Papéis e escopos

| Papel | Escopo | Natureza |
|---|---|---|
| `super_admin` | Plataforma inteira (cross-tenant) | Platform-scoped |
| `admin` | Plataforma inteira (cross-tenant), sem config de plataforma/billing | Platform-scoped |
| `operator` | Plataforma inteira (despacho operacional) | Platform-scoped |
| `driver` | **Apenas seus próprios** dados (driver_id = auth.uid → drivers.id) | Platform-scoped |
| `business_owner` | **Apenas sua `organization_id`** | Org-scoped |
| `business_user` | **Apenas sua `organization_id`** (subset do owner) | Org-scoped |

### Matriz MVP (permissões por papel)

Recursos: **ORG** (organizations), **BIZ** (businesses/business_locations),
**DRV** (drivers/driver_locations/driver_availability), **COR** (delivery_requests/
delivery_quotes/dispatch_rounds/delivery_offers/bids/delivery_assignments/
delivery_events/proof_of_delivery), **NOT** (notifications), **SYS**
(webhook_events/integration_events — sistema apenas).

Legenda: **V**er, **C**riar, **E**ditar, **X**cancelar, **D**espatch/atribuir,
**R**esponder offer/bid, **T**ransitar status.

| Recurso | super_admin | admin | operator | business_owner | business_user | driver |
|---|---|---|---|---|---|---|
| ORG | V/C/E | V/E | V | — | — | — |
| BIZ | V/C/E | V/E | V | V/C/E (sua org) | V (sua org) | — |
| DRV | V/C/E | V/E | V/C/E | V (sua org¹) | V (sua org¹) | V/E² (self) |
| COR | V/C/E/X/D/T | V/X/D/T | V/D/T | V/C/X (sua org) | V/C (sua org) | V/R/T³ (self) |
| NOT | V | V | V | V (sua org) | V (sua org) | V (self) |
| SYS | — | — | — | — | — | — |

Notas:
1. business_owner/business_user **veem** drivers disponíveis na sua org (para escolher
   quem despachar em fluxos manuais), mas **não criam/editam** drivers (drivers são
   platform-scoped, gerenciados por admin).
2. driver edita **apenas** própria localização (`driver_locations`) e própria
   disponibilidade (`drivers.current_availability_status` via `set_driver_availability`).
   Não edita seus próprios dados cadastrais (account_status etc.) — isso é do admin.
3. driver responde (R) offers/bids **dirigidas a ele** e transita (T) status das
   corridas **atribuídas a ele** (`delivery_assignments.driver_id = self`).
   Não cria nem cancela corridas.

### Regras de ouro

1. **Driver nunca vê corrida alheia.** RLS filtra `delivery_*` por
   `delivery_assignments.driver_id = auth.uid → drivers.id` (ou offer dirigida a ele).
2. **business_* nunca vê outra org.** RLS filtra por `organization_id` da membership.
3. **admin/operator veem tudo (cross-tenant)** mas só platform-scoped actions; não
   acessam SYS (webhooks/integration_events) — SYS é exclusivo do system-scoped
   (`service_role`).
4. **Atribuição (D) é sempre via `claim_delivery` RPC**, nunca UPDATE direto — mesmo
   para admin/operator. O RPC é o único caminho (regra mestra + ADR-007).
5. **Transição de status (T) é sempre via `transition_delivery` RPC** — ninguém seta
   `status` direto.
6. **Cancelamento (X) de corrida já atribuída** só por admin/operator/dono — driver
   não cancela, sinaliza desistência (que vira `assigned → searching_driver` via RPC).

### Mapeamento para implementação

- **RPCs DEFINER (0016)** = **função de execução + autorização interna**: as 4 RPCs
  viram `SECURITY DEFINER` e validam `auth.uid()` internamente (Modelo B). Assim o
  direito de AGIR (C/E/X/D/R/T) é imposto no banco, não só no serviço. `authenticated`
  não recebe DML de domínio — a única mutação user-facing é a RPC.
- **RLS policies (0017)** = **visibilidade** (V): quem vê quais linhas de cada tabela.
  - `organization_id` para ORG/BIZ/COR/NOT (business_*).
  - `driver_id = self` (via offers/assignments) para COR do driver.
  - `policy USING (true)` para platform roles (admin/operator) com grant de SELECT.
  - Helpers `is_platform_admin()` / `my_org_ids()` / `my_driver_id()` / `can_view_delivery_request()`
    (SECURITY DEFINER) resolvem o caller para as policies.
- **Service authz** = **direito de agir** (C/E/X/D/R/T) validado na camada de serviço
  ANTES de chamar a RPC. Ex.: business_user tenta cancelar → serviço checa papel + org
  → `transition_delivery(... 'cancelled')`. A RPC (DEFINER) revalida via `auth.uid()`
  — defesa em profundidade (serviço E banco).
- **Grants (0015)** = least-privilege: `service_role` DML em tudo + EXECUTE nas 4 RPCs;
  `authenticated` SELECT em 20 tabelas (sob RLS `0017`) + EXECUTE nas 3 RPCs user-facing
  + INSERT/UPDATE só em `driver_locations`; `anon` nada.

## Fora do escopo (adiado)

- **Granularidade por campo** (ex.: business_user vê preço mas não edita) — só quando
  houver segundo caso real.
- **Permissões por business_location** dentro de uma org multi-unidade — MVP é 1:1:1.
- **RBAC dinâmico** (papeis customizáveis por tenant) — MVP usa os 6 fixos.
- **Delegação** (business_owner convida business_user) — fluxo de convite na Sessão 05.
- **Auditoria de negação de acesso** (log de "tentou acessar X e foi barrado") —
  Sessão 22 (security review).

## Consequências

- Sessão 04 implementa 0015 (grants) + 0016 (RPCs DEFINER) + 0017 (RLS policies) +
  `test_vio10_authz.sql` a partir de uma **spec fixa**, não inventada.
- O modelo suporta multi-tenant sem reconstrução (RLS por `organization_id` já escala
  para N orgs); só as policies de platform roles mudariam se surgisse um segundo tenant
  com regras diferentes.
- `driver` e `business_*` são os isolamentos mais sensíveis; testes de autorização
  são gate destas superfícies.

## Referências

`docs/SECURITY.md` (RBAC, isolamento multiempresa), `BACKEND.md` §6 (Autorização),
`ARCHITECTURE.md` §3.1 (user-scoped vs system-scoped), `0004_identity_tenancy.sql`,
ADR-001, ADR-007.