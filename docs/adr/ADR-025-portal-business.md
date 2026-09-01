# ADR-025 — Portal business (read-side via RLS, helper `my_org_memberships()`, read-only MVP)

- **Status**: Aprovado
- **Data**: 2026-09-01
- **Sessão**: 19

## Contexto

A Sessão 18 (ADR-024) entregou o Dashboard admin e deixou documentado um **GAP LATENTE
business**: `resolveLandingPath` (`lib/auth/landing.ts`) lia `organization_memberships`
diretamente via client user-scoped, mas essa tabela **não tem SELECT grant a `authenticated`**
(migration 0015 — metadados de authz sensíveis; "backend resolve server-side"). A RLS
`orgm_sel` (0017) é **moot sem grant** — o mesmo bug confirmado live para o caso análogo
`user_platform_roles` (fixado em 0030 com o helper `my_platform_role()`). Resultado: o ramo
business do redirect pós-login falhava com `permission denied`, e **não existia portal
business** — um usuário `business_owner`/`business_user` logava e caía em `no_role`.

Esta sessão fecha o gap (helper DEFINER análogo a `my_platform_role()`/`my_email()`) e
constrói o **Portal business — read-only MVP**, espelhando a Sessão 18 (read-side via RLS,
polling, **sem `service_role`, sem mutação**). **Regra mestra**: frontend só apresenta estado
oficial; nada é inventado; `service_role` nunca vaza ao browser.

### Decisões do usuário (AskUserQuestion / plano aprovado)

- **Escopo**: read-only MVP (alinhado ao CLAUDE.md/PLAN.md). Overview = KPIs de
  **corridas/custo** do tenant (ativas, terminais, entregues hoje + volume em centavos,
  falhas recentes). Detalhe = timeline + resumo + itens + cotação (customer price) + mapa c/
  posição live do entregador (polling 15s). **Sem** KPI de disponibilidade de entregadores
  (conceito platform-wide/admin — o business owner olha pras próprias corridas).
- **Sem** criação de corrida / gestão de unidades / entregadores → sessão futura ("ações de
  gestão").

### Restrição viva

Geo 501 (Sessão 20) ainda bloqueia o dispatch chain end-to-end — o fluxo normal
`draft → quoted → searching_driver → assigned → ... → in_transit` exige routing provider para
`create_quote`. A validação live do portal usa **fixture SQL** (corridas em vários estados) —
não se simula PASS do dispatch (regra mestra).

## Decisões

### D1 — Read via client user-scoped + RLS `can_view_delivery_request`/`my_org_ids()`, sem `service_role`

O read-side do portal business vai **direto via client user-scoped (cookie JWT) + RLS** —
**sem `service_role`**, sem RPC de leitura nova, sem grant de DML. A RLS já libera o business
user a ler **tudo do próprio tenant** desde a Sessão 04: as policies de
`0017_rls_policies.sql` usam `can_view_delivery_request(id)` (→ `organization_id = any
my_org_ids()`) em `delivery_requests` e **todas as filhas** (dispatch_rounds, delivery_offers,
bids, delivery_events, delivery_items, delivery_quotes, delivery_assignments,
proof_of_delivery); `orgs_sel`/`biz_sel`/`bizloc_sel` escopam organizations/businesses/
business_locations por `my_org_ids()`. Logo o business vê o detalhe completo das próprias
corridas (incluindo ofertas/lances/rodadas) sem filtro explícito na query — a RLS escopa. Mesmo
padrão da Sessão 17/18 (camada de aplicação pura).

### D2 — Read-only MVP

Nenhuma mutação nesta sessão. O portal apenas **apresenta** estado oficial. Ações (criar
corrida, cancelar, gerenciar unidades/entregadores) ficam para uma sessão futura de gestão, via
RPCs DEFINER existentes (`create_delivery_request`, `transition_delivery`, gestão 0020/0019)
com gate de authz. `service_role` não é necessário para leitura e **não vaza** ao browser
business.

### D3 — Helper `my_org_memberships()` SECURITY DEFINER (exceção, espelho 0030/0019)

`organization_memberships` **não tem SELECT grant a `authenticated`** (0015 — metadados de
authz sensíveis; "backend resolve server-side"); a RLS `orgm_sel` (0017) é **moot sem grant**
(confirmado live para o caso análogo `user_platform_roles`). A aplicação precisa resolver o
papel/tenant do caller no login (`resolveLandingPath`) e no handler/context business
(defense-in-depth D4). Solução: **migration 0031** cria `public.my_org_memberships()` —
`SECURITY DEFINER`, `set search_path to public, pg_catalog`, `returns table(organization_id
uuid, role text)`, lê **as próprias rows** (`user_id = auth.uid()`, ordenado por `created_at`),
retorna vazio se não autenticado. `grant execute to authenticated, service_role`.

- **Espelho** de `my_platform_role()` (0030) e `my_email()` (0019): leitura via DEFINER sem
  expor a tabela ao `authenticated`. Diferença: **set-returning** (1 user → N orgs), enquanto
  `my_platform_role` é 1:1 (scalar).
- `my_org_ids()` (0017, DEFINER, já granted a `authenticated`) **não muda** — continua usado
  **internamente** pelas policies RLS. `my_org_memberships()` é para a **camada de aplicação**
  ler role/tenant.
- `resolveLandingPath` ramo business: `await client.rpc("my_org_memberships")` em vez de select
  direto (que falhava com `permission denied`). `resolveOrgMemberships` extraído p/ reuso
  (login + handler + context).
- **Nenhuma tabela/coluna/enum novo.** Nenhum grant de DML. Exceção justificada (gap real
  confirmado).

### D4 — Defense-in-depth 403 `not_authorized` no handler

O middleware só checa **sessão** (307 → `/auth/login` em `/business`), não membership. Sem
gate explícito, um driver autenticado (cookie JWT válido) receberia **vazio** em
`/api/business/*` — não erro, mas sem dados (RLS escopa a `my_org_ids()` vazia). O
`handleBusinessGet` faz defense-in-depth: `getUser` → 401 `unauthenticated` se sem user;
`resolveOrgMemberships` → **403 `not_authorized`** se memberships vazias (não chama `run`);
só então `run(correlationId, url, ctx)` c/ `ctx.memberships`. Espelho de `handleAdminGet`
(Sessão 18 D5), mas membership é set-returning.

### D5 — Reuso de query functions + UI admin (props parametrizadas)

As queries `listDeliveries`/`getDeliveryDetail`/`getDeliveryPositions`/`parsePointPosition`
de `admin-reads.ts` são **RLS-agnostic** — o gate de authz vive no handler, o escopo na RLS.
Logo são **re-exportadas** de `business-reads.ts` sem duplicação. Para business,
`listDeliveries` é chamada **sem** `businessId` (RLS escopa ao tenant).

UI: os componentes admin (`DeliveriesTable`, `StatusFilter`, `DeliveryMap`,
`DeliveryDetailTabs`, `DeliveryTimeline`) são **refatorados com props opcionais** (defaults
admin) — `detailHref`, `basePath`, `positionsUrl` — mantendo **compatibilidade backward** (admin
continua funcionando sem mudança nos callers). O portal business reusa os mesmos componentes
com props business. `overview-kpis` é novo (KPIs business, sem drivers). Reuso direto:
`lib/client/fetcher.ts` (`apiGet`), `lib/admin/status.ts`, `components/ui/*`, `LogoutButton`.

### D6 — Sem migration nova além de 0031

Apenas a migration 0031 (`my_org_memberships`). Camada de aplicação pura no restante (espelho
Sessão 15/17/18): sem RPC/enum/grant de DML novos, sem tabela nova. Os 4 RPCs driver-facing já
eram finais desde Sessões 09-12.

### D7 — Frontend só apresenta estado oficial

O portal nunca inventa estado, preço, ETA, entregador ou status. Tudo vem do backend via RLS
(user-scoped). Polling refresca o estado oficial; nada é otimistic-updated. Posição do
entregador no mapa vem de `driver_locations` (RLS `can_view_delivery_request` no detalhe da
corrida do próprio tenant).

### D8 — Overview sem KPI de entregadores

Diferente do admin overview (D8 ADR-024), o overview business **não** mostra disponibilidade
de entregadores. Motivo: disponibilidade é um conceito **platform-wide** (pertence ao
operador); o business owner olha pras **próprias corridas** (ativas, terminais, entregues hoje
+ volume em centavos inteiros, falhas recentes). Evita expor dados de outros tenants e reflete
o domínio (tenant ≠ operador).

### D9 — Validação real (geo 501 Sessão 20 bloqueia dispatch chain → fixture SQL)

Validação live em dev (real, não simulada): `next dev` + curl + Auth Admin API. Sem cookie →
401; cookie de driver → **403** `not_authorized`; cookie business → 200 em `/me`, `/overview`,
`/deliveries`, `/deliveries/{id}`, `/positions`; login → redirect `/business` (destrava o
redirect); SSR 3 páginas 200; `my_org_memberships` não vaza role de outros (DEFINER lê só
`auth.uid()`). Dispatch chain completo **não** validado live (geo 501) → fixture SQL.
Renderização visual Leaflet no browser → usuário. Não simulado PASS.

## Consequências

- **Redirect business destravado**: `business_owner`/`business_user` logam → `/business` (gap
  0015/0017 fechado via 0031, espelho 0030/0019).
- **Portal business read-only** funcional: overview, lista, detalhe c/ timeline + mapa + posição
  live — tudo via RLS, sem `service_role`.
- **Reuso máximo**: queries + UI admin parametrizadas — zero duplicação de lógica de domínio.
- **Dívida**: gestão (criar corrida, unidades, entregadores, cancelar) → sessão futura. Geo
  provider (Sessão 20) ainda bloqueia o fluxo end-to-end.
- **`organization_memberships`** permanece sem SELECT grant a `authenticated` (intencional,
  metadados sensíveis); leitura só via DEFINER.

## Recursos

- Migração: `supabase/migrations/0031_my_org_memberships.sql`.
- Ref refs: ADR-023 (PWA driver), ADR-024 (dashboard admin — D1/D4/D8 espelhados), ADR-010
  (RBAC/RLS `my_org_ids()`), ADR-005 (provider abstraction — geo 501).