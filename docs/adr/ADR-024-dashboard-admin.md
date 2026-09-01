# ADR-024 — Dashboard admin (read-side via RLS, Leaflet+OSM, polling, read-only MVP)

- **Status**: Aprovado
- **Data**: 2026-09-01
- **Sessão**: 18

## Contexto

A Sessão 17 (ADR-023) entregou a primeira UI — o PWA do entregador — e o read-side
driver (`GET /api/driver/*`, user-scoped + RLS `can_view_delivery_request`/
`my_driver_id()`). Mas o ViO10 ainda tinha **zero superfície admin**: o login já
redireciona platform roles → `/admin` (`resolveLandingPath` em `lib/auth/landing.ts`),
o middleware já protege `/admin` (307 → `/auth/login`), porém **não existia
`app/(admin)/` nem `app/api/admin/`**. FRONTEND.md §4 descreve o dashboard: corridas
por estado, entregadores, volume/valores, falhas, timeline de `delivery_events`, mapa
operacional.

A RLS libera o admin a ler tudo desde a Sessão 04: as policies de
`0017_rls_policies.sql` usam `is_platform_admin()` (inclui `super_admin`/`admin`/
`operator`) para SELECT **cross-tenant** em todas as tabelas de domínio —
`delivery_requests` + filhas (items/quotes/rounds/offers/bids/assignments/events/pod),
`drivers`, `driver_locations`, `vehicles`, `organizations`/`businesses`/
`business_locations`, `pricing_rules`, `notifications`. Os grants `0015` dão SELECT
a `authenticated` nessas tabelas. Logo o read-side do admin vai **direto via client
user-scoped + RLS** — **sem `service_role`, sem RPC/enum/grant/migration novo** (mesmo
padrão da Sessão 17, camada de aplicação pura).

`service_role` só seria preciso para `webhook_events`/`integration_events` (SYS,
default-deny, fora do MVP). Admin muta via RPCs existentes (`update_driver_status`,
`transition_delivery`, gestão 0020/0019) com gate `is_super_or_admin()` — mas **esta
sessão é read-only** (decisão do usuário); ações ficam para uma sessão futura de gestão.

**Restrição viva**: geo 501 (Sessão 20) ainda bloqueia o dispatch chain end-to-end. A
validação live do dashboard usa **fixture SQL** (corridas em vários estados + drivers +
`driver_locations`) — não se simula PASS do dispatch (regra mestra).

### Decisões do usuário (AskUserQuestion / plano aprovado)

- **Telas MVP**: Overview operacional + Lista + detalhe de corrida. (Entregadores e
  Empresas/unidades fora do MVP — futura sessão de gestão.)
- **Mapa**: **Leaflet + OSM** (open-source, tiles OpenStreetMap, **zero novas
  credenciais** — não depende de Google; a key Google da Sessão 20 é server-side/IP e
  não serve para frontend). Marcadores coleta/destino/entregador.
- **Live updates**: **polling 15-30s** (consistente com a Sessão 17; **nenhum client
  Supabase no browser** — tudo via Route Handlers same-origin). Realtime adiado.
- **Ações**: **Read-only first** — dashboard só apresenta estado oficial; sem mutação.

## Decisões

- **D0 — Paleta de marca**: branco (background) + **laranja `#fe7845`** (accent/
  primária). Mapeado em `app/globals.css`: `--primary` → `oklch(0.72 0.18 41)`
  [#fe7845], `--primary-foreground` → escuro quente `oklch(0.18 0.03 41)` (contraste
  white-on-orange 2.63 falha AA; dark-on-orange ~6.66 passa). `--ring` e `--accent`
  alinhados ao laranja, em `:root` e `.dark`. Estados de status continuam com cores
  semânticas (success/warning/destructive) além do laranja de marca. Aplica-se ao
  restante do frontend (driver já herdou via tokens).
- **D1 — Admin read via user-scoped + RLS (sem service_role)**: leitura direta por
  client user-scoped (cookie JWT, `auth.uid()`, `is_platform_admin()` aplica
  cross-tenant). Mesmo padrão da Sessão 17. `service_role` **não usado em read**.
  Endpoints admin em árvore nova `app/api/admin/*` (user-scoped, admin-gated) —
  distintos de `/api/driver/*` (driver-gated) e `/api/internal/*` (system,
  `x-internal-api-key`).
- **D2 — Read-only MVP**: nenhuma mutação; dashboard só apresenta. Ações admin
  (cancelar, offboarding, gestão) → sessão futura.
- **D3 — Leaflet + OSM**: mapa client-side vanilla `leaflet@1.9.4` (não `react-leaflet`,
  para evitar fricção React 19). Tiles OSM, **sem key**. Coords: `delivery_requests`
  tem `pickup_latitude/longitude` + `delivery_latitude/longitude` (double, expostos).
  Para `driver_locations.position` (geography sem colunas lat/lng auxiliares) →
  **parse GeoJSON retornado pelo PostgREST** em TS (`{type:"Point",coordinates:[lng,lat]}`,
  lng primeiro) com fallback WKT `POINT(lng lat)` — **sem migration** (`parsePointPosition`
  em `lib/services/admin-reads.ts`). `leaflet` importado dinamicamente dentro do
  `useEffect` (SSR-safe — leaflet toca `window` no import); `divIcon` com SVG inline
  evita o bug de path do ícone default no bundler.
- **D4 — Polling 15-30s foreground**: overview 30s, detalhe (mapa/positions) 15s. Para
  quando `document.visibilityState!=='visible'`. Sem client Supabase no browser
  (todas as leituras via Route Handlers same-origin, cookie JWT).
- **D5 — `getAdminContext()` + `handleAdminGet` (defense-in-depth)**: middleware só
  checa sessão, não role. O handler resolve a role do caller via `resolvePlatformRole`
  (refatorado de `resolveLandingPath` em `lib/auth/landing.ts` — query da própria row
  em `user_platform_roles`, RLS `upr_sel`) → se não for platform role → **403
  `not_authorized`**. RLS já filtra, mas o 403 evita servir vazio a um driver
  autenticado que bata em `/api/admin/*`. Server Components sob `(admin)` usam
  `getAdminContext()` (mesmo lookup) → `{client, role}` ou `null` (redirect).
- **D6 — Sem migration/RPC/enum/grant novo — COM EXCEÇÃO (0030)**: camada de
  aplicação pura (Sessões 15/17). Coords de `driver_locations` via parse (D3). **Exceção
  descoberta em validação live**: `resolvePlatformRole` (reuso por `resolveLandingPath`
  + `getAdminContext` + `handleAdminGet`) lia `user_platform_roles` via client user-scoped,
  mas `authenticated` **não tem SELECT grant** na tabela (0015 — metadados de authz
  sensíveis; "backend resolve server-side"); a RLS `upr_sel` (0017) é **moot sem grant**
  (confirmado live: `permission denied for table user_platform_roles`) → admin autenticado
  retornava null → 403 em `/api/admin/*` e redirect ao `/driver` no login (mascarado desde
  a Sessão 17 — só drivers foram testados live; driver sem role → null → `/driver` é o
  caminho correto, então o bug do admin nunca apareceu). Fix alinhado ao ADR-010 Modelo B:
  **migration 0030** adiciona `my_platform_role()` **SECURITY DEFINER** (espelho de
  `my_email()` — lê a própria linha `user_id = auth.uid()`, devolve role text, **sem abrir
  SELECT da tabela ao `authenticated`**) + `grant execute to authenticated, service_role`.
  `resolvePlatformRole` agora chama `client.rpc('my_platform_role')`. **GAP LATENTE
  (business → Sessão 19)**: `organization_memberships` tem o mesmo padrão (sem SELECT
  grant + RLS `orgm_sel` moot); o redirect business em `resolveLandingPath` ainda lê a
  tabela diretamente — funcionará só após helper análogo na Sessão 19.
- **D7 — Frontend só apresenta estado oficial**: Server Components leem via
  `getAdminContext()` + `admin-reads` (RLS) e passam estado oficial a client
  components. Mapa e timeline refletem o banco; nada é inventado no client (regra
  mestra/FRONTEND §2). `next build` limpo; `tsc` limpo; vitest sem regressão.
- **D8 — operator**: vê tudo (RLS) mas `is_super_or_admin()` o exclui de mutação —
  indiferente no MVP read-only. Futura UI de gestão diferencia `is_super_or_admin()`.

## Estrutura entregue

### Infra (Fase 1)

- `lib/auth/landing.ts` — extraído `resolvePlatformRole(client, userId)` (reuso:
  login + admin handler/context).
- `lib/server/admin-context.ts` — `getAdminContext()` → `{client, role}` ou `null`.
- `lib/api/admin-handler.ts` — `handleAdminGet` (espelho de `handleUserGet`, com
  checagem de role → 403; sem idempotency ledger; sem `service_role`).
- `components/ui/{table,select,tabs}.tsx` — primitivas hand-rolled (`cva`+`cn`).
- `app/(admin)/layout.tsx` — header (logo laranja + nav `/admin`+`/admin/deliveries`
  + `LogoutButton`), `max-w-7xl` desktop, sem `PWARegister`.

### Read-side (Fase 2)

- `lib/services/admin-reads.ts` — `getOverview`/`listDeliveries`/`getDeliveryDetail`/
  `getDeliveryPositions` + `parsePointPosition` (GeoJSON/WKT). `RpcResult`-shaped,
  leitura user-scoped, agregação client-side (volume MVP).
- 4 endpoints (todos `handleAdminGet`, `cache: no-store`):
  `GET /api/admin/overview`, `/api/admin/deliveries` (`status`,`business_id`,`limit`,
  `offset`), `/api/admin/deliveries/{id}`, `/api/admin/deliveries/{id}/positions`.

### UI (Fase 3)

- `app/(admin)/admin/page.tsx` — overview (Server) → `<OverviewKpis/>` (polling 30s).
- `app/(admin)/admin/deliveries/page.tsx` — lista (Server, `searchParams` Promise) →
  `<DeliveriesTable/>` + `<StatusFilter/>` (Select nativo, navegação server-driven
  via URL) + `<Pagination/>` (`?offset=`).
- `app/(admin)/admin/deliveries/[id]/page.tsx` — detalhe (Server) →
  `<DeliveryDetailTabs/>` (Tabs: Resumo / Timeline / Mapa / Offers).
- `components/admin/{overview-kpis,deliveries-table,status-filter,delivery-timeline,
  delivery-map,delivery-detail-tabs}.tsx`.
- `lib/admin/status.ts` — `statusBadge`/`availabilityBadge`/`eventLabel` (**24 tipos**
  válidos de `delivery_event_type`, conferidos live no enum do dev).

## Consequências

- Dashboard operacional utilizável **hoje**, sem depender de Google Maps (Sessão 20).
  Dispatch chain completo (quote→searching→offer→assigned) só será visível end-to-end
  após a Sessão 20 (geo 501); até lá, fixture SQL injeta corridas em vários estados.
- `service_role` permanece confinado ao backend/internal (`x-internal-api-key`); o
  browser admin nunca o recebe (regra mestra íntegra).
- Refatoração `resolvePlatformRole` é reuso seguro (mesma query que já funcionava no
  login); login existente preservado.
- Realtime adiado (polling no MVP). Telas de Entregadores/Empresas e ações de gestão
  (cancelar/offboarding) → futura sessão.

## Verificação

- `tsc --noEmit` limpo; `next build` limpo (todas as rotas admin presentes).
- vitest **235/235** (19 suítes, +28 novos: `admin-handler.test.ts` 7, `admin-reads.
  test.ts` 21 cobrindo `parsePointPosition` GeoJSON/WKT/**EWKB hex** + overview agregação
  + listDeliveries paginação/filtro/clamp + detail timeline sort + positions parse).
- Regressão DB: `verify_sessao16.sh` → reset + replay **0001→0030 (30/30 limpo)** +
  inventário íntegro (28 tabelas, 28 RLS, `anon`=0) + **10/10 suítes PASS** (418
  asserções, zero regressão). 0030 só adiciona função + grant, não toca RPCs/RLS
  existentes.
- **Live (dev, real — não simulado, regra mestra)** via `next dev` + curl + Auth Admin
  API + fixture SQL (4 corridas em estados distintos + drivers + `driver_locations`):
  - 401 sem cookie; **307** `/auth/login?redirect=` sem sessão em `/admin`.
  - **403 `not_authorized`** com cookie de driver em `/api/admin/*` (defense-in-depth).
  - **Admin cookie → 200**: `/api/admin/overview` (KPIs coerentes: assigned:1,
    in_transit:1, delivered:1, cancelled:1, drivers busy:1/offline:1, falha d4444);
    `/api/admin/deliveries?status=assigned` (a1111, business "Loja Congonhas",
    driver "Driver Teste"); `/api/admin/deliveries/{id}` 200 (b2222 in_transit —
    timeline 5 eventos; a1111 — quote com todos componentes; c3333 — delivered +
    delivered_at); `/api/admin/deliveries/{id}/positions` 200 (pickup/delivery diretos
    + **driver position parseada de EWKB hex** → {lng:-43.855, lat:-20.915}).
  - SSR: `/admin`, `/admin/deliveries`, `/admin/deliveries/{id}` → 200 sem crash
    markers (content presente, ~23-37 KB).
- **3 bugs reais achados + corrigidos + provados live** (mock unitário não pegou —
  prova do "não simulado"):
  1. **Grant gap `user_platform_roles`** (D6-exceção): `authenticated` sem SELECT grant
     → `resolvePlatformRole` null → 403. Fix: migration 0030 `my_platform_role()`
     SECURITY DEFINER + `resolvePlatformRole` via `.rpc()`.
  2. **Hint FK composta `bids`**: `bids!delivery_offer_id` (hint por coluna) não resolve
     FK **composta** `bids_offer_driver_fk` (delivery_offer_id+driver_id → id+driver_id)
     → PGRST200 → `internal_error` no detalhe. Fix: `bids!bids_offer_driver_fk`
     (nome da constraint).
  3. **EWKB hex**: PostgREST/Supabase devolve `geography` como **hex EWKB**
     (`0101000020E6100000...`), não GeoJSON/WKT → `parsePointPosition` retornava null
     (driver sem posição no mapa). Fix: branch EWKB no parser (little/big-endian, com/
     sem SRID, guarda geomType===1 Point).

## Ressalva (regra mestra)

- Dispatch chain completo não validado live (geo 501, Sessão 20) — fixture SQL injeta
  corridas em vários estados. **Read-only**: nenhuma mutação admin nesta sessão.
- Mapa usa Leaflet/OSM (não Google Maps JS). Google Maps server-side Routes/Geocoding
  permanece Sessão 20. Realtime → futura (polling no MVP).
- **Renderização visual do Leaflet no browser** (tiles OSM carregando, markers/polyline)
  não verificada por curl (exige execução JS no browser) — API `/positions` retorna
  coords corretas e `leaflet@1.9.4`+CSS instalados; validação visual fica p/ usuário.
- **GAP LATENTE business** (D6-exceção): `organization_memberships` sem SELECT grant
  a `authenticated` → redirect business em `resolveLandingPath` ainda lê a tabela
  diretamente (retorna null → `no_role`). Sem user business no MVP/Sessão 18. Fix
  (helper análogo) → Sessão 19.