# FRONTEND.md — Frontend do ViO10

## 1. Um codebase, três superfícies

Tudo em **Next.js 16.3.3 (App Router)**, num único projeto, organizado por
**route groups**:

- `/app/(driver)/...` — **PWA do entregador** (prioridade: uso rápido no celular).
- `/app/(admin)/...` — **Dashboard ViO10** (central operacional).
- `/app/(business)/...` — **Portal da empresa cliente**.

Stack de UI: TypeScript, Tailwind CSS, shadcn/ui.

## 2. Princípio inegociável

> **O frontend apresenta estado oficial e coleta ações. Nunca inventa estado.**

- Status de corrida, preço, ETA, entregador atribuído — tudo vem do backend.
- Nenhuma decisão financeira ou de estado é tomada no frontend.
- Regras de negócio **não** são duplicadas no frontend. Se a regra importa para
  consistência, ela vive no backend; o frontend só reflete.

## 3. PWA do entregador

> **Implementado na Sessão 17 (ADR-023).** Stack: Tailwind CSS v4 + shadcn/ui
> hand-rolled (`cva`+`cn`), route group `app/(driver)/...`, login via Server Action
> (`signInWithPassword`, redirect por role), PWA via `app/manifest.ts` + service
> worker (`public/sw.js`) + `<PWARegister/>`. **Nenhum client Supabase no
> browser** — toda auth é server-side (cookie httpOnly); leitura/escrita por Route
> Handlers same-origin. Atualizações por **polling** (10s, foreground); Realtime
> adiado.

Prioridade absoluta: **uso rápido no celular**. Botões grandes, mínimo de cliques,
excelente mobile, estados de loading/erro/sucesso, tolerância a conexão instável,
proteção contra clique duplicado (idempotência real no backend — ADR-020 D7; o disable
na UI é UX).

Fluxos: login → disponível/indisponível → oportunidade atual → ACEITAR/RECUSAR/
FAZER LANCE → corrida atribuída → navegar até coleta → cheguei → produto coletado →
iniciar entrega → navegar até destino → concluir entrega → prova de entrega →
histórico básico → ganhos básicos.

### Páginas e componentes (Sessão 17)

- `app/auth/login/{page,actions}.tsx` — login Server Action + redirect por role
  (`/admin` | `/driver` | `/business`).
- `app/(driver)/layout.tsx` — header (logo + Histórico + Logout) + `<PWARegister/>`
  + safe-area.
- `app/(driver)/driver/page.tsx` — home (Server Component): corrida ativa →
  `<ActiveDeliveryCard/>`; senão → `<AvailabilityToggle/>` + `<OpportunityPanel/>`.
- `app/(driver)/driver/delivery/[id]/page.tsx` — detalhe (Server Component) →
  `<DeliveryStateMachine/>` (client): botões por estado, POD pickup (notes) / POD
  delivery (receiver_name + otp_code), polling do estado oficial.
- `app/(driver)/driver/history/page.tsx` — histórico + ganhos (30d).
- Componentes: `components/driver/{availability-toggle,opportunity-panel,
  active-delivery-card,delivery-state-machine,location-tracker,logout-button}.tsx`;
  `lib/hooks/use-driver-location.ts`; `lib/client/fetcher.ts` (`apiGet`/`apiPost`);
  `lib/server/driver-context.ts` (`getDriverContext`).
- Primitivas UI: `components/ui/{button,card,input,label,badge,skeleton}.tsx`.

### Read-side do driver (ADR-023 D1 — sem RPC)

Leitura direta via client user-scoped (cookie JWT, RLS). **Sem RPC/enum/grant novo.**
Endpoints: `GET /api/driver/{me,opportunity,deliveries/active,deliveries/history,
earnings}` + `POST /api/driver/location` (telemetria — única mutação direta do
`authenticated`, RLS `driver_id = my_driver_id()`). Handler `handleUserGet`
(`lib/api/user-handler.ts`); service `lib/services/driver-reads.ts`.

### Localização do entregador

- Não presumir rastreamento confiável em background.
- Durante corrida ativa **e PWA em foreground**: atualização ~10s (configurável).
- Sempre há `location_timestamp`; coordenada antiga é **stale** e não pode ser
  tratada como atual em decisões críticas.
- Tracking persistente em background, se um dia necessário, provavelmente exigirá
  app nativo. Documentado em `docs/GEOLOCATION.md`.

## 4. Dashboard ViO10 (admin)

Central operacional: corridas por estado, entregadores disponíveis/ocupados/offline,
empresas, volume, valores, falhas. Tela de detalhe da corrida com **timeline de
`delivery_events`**. Ações administrativas só quando há regra de negócio
correspondente — **nada de editar status arbitrariamente**. Mapa operacional com
coleta/destino/entregador.

### Realização (Sessão 17 / ADR-023 + Sessão 18 / ADR-024)

- **Login + redirect por role** (`resolveLandingPath` em `lib/auth/landing.ts`):
  platform role (super_admin/admin/operator) → `/admin`; driver → `/driver`;
  business → `/business` (RESOLVIDO Sessão 19 — ver ADR-025 D3); nenhum → recusa.
  Platform role via RPC SECURITY DEFINER `my_platform_role()` (migration 0030) —
  `user_platform_roles` sem SELECT grant a `authenticated`. Membership business via RPC
  SECURITY DEFINER `my_org_memberships()` (migration 0031) — `organization_memberships`
  sem SELECT grant a `authenticated` (mesmo padrão 0030/0019).
- **PWA Entregador** (Sessão 17): `app/(driver)/...`, polling 10s foreground,
  login Server Action, manifest+SW, read-side sem RPC (RLS `can_view_delivery_request`/
  `my_driver_id()`), `POST /api/driver/location` (WKT PostgREST).
- **Dashboard admin** (Sessão 18, **read-only MVP**): `app/(admin)/{admin,
  admin/deliveries, admin/deliveries/[id]}` + `app/api/admin/{overview,deliveries,
  deliveries/[id],deliveries/[id]/positions}`. Read via client **user-scoped** + RLS
  `is_platform_admin()` (cross-tenant), **sem `service_role`**. `handleAdminGet`
  (defense-in-depth: 403 `not_authorized` se não platform role). **Polling** 30s
  (overview) / 15s (mapa). **Mapa Leaflet+OSM** (vanilla `leaflet@1.9.4`, sem credencial;
  `driver_locations.position` geography parseado de **EWKB hex** em TS — sem migration
  p/ lat/lng). Paleta de marca: **branco + laranja `#fe7845`** (D0). Telas de
  Entregadores/Empresas e ações de gestão → sessão futura.
- **Portal business** (Sessão 19, **read-only MVP** — ADR-025): `app/(business)/{business,
  business/deliveries, business/deliveries/[id]}` + `app/api/business/{me,overview,
  deliveries,deliveries/[id],deliveries/[id]/positions}`. Read via client **user-scoped** +
  RLS `can_view_delivery_request`/`my_org_ids()` (escopa ao tenant), **sem `service_role`**.
  `handleBusinessGet` (defense-in-depth: 403 `not_authorized` se sem membership).
  **Overview** = KPIs de corridas/custo do tenant (ativas, terminais, entregues hoje +
  volume em centavos inteiros, falhas recentes) — **sem** KPI de entregadores (D8).
  **Detalhe** = timeline + resumo + itens + cotação (customer price) + mapa Leaflet c/
  posição live do entregador (polling 15s). Reuso máximo: query fns `admin-reads.ts`
  re-exportadas + UI admin via props parametrizadas (`detailHref`/`basePath`/`positionsUrl`,
  defaults admin backward compatible). Paleta branco+laranja `#fe7845`. Gestão (criar
  corrida, unidades, entregadores) → sessão futura.

## 5. Portal da empresa

Solicitar corrida, obter cotação, confirmar, acompanhar, histórico, repetir
entrega, comprovante, cobranças, gerenciar usuários/unidades. WhatsApp continua
canal válido; o portal **não** é obrigatório para usar o ViO10. Isolamento total
entre empresas. **Realização (Sessão 19 / ADR-025)**: read-only MVP entregue — ver §4
acima (overview + lista + detalhe). Ações de gestão (criar corrida, unidades,
entregadores) → sessão futura.

## 6. Convenções

- Consumo de estado via chamadas ao backend (Route Handlers/Server Actions
  originados no frontend) e, onde fizer sentido, **Supabase Realtime** para
  atualizações ao vivo (ex.: posição/status no dashboard).
- Componentes de UI em shadcn/ui; design tokens compartilhados entre as três
  superfícies.
- Tratamento de erro e loading em toda chamada; nunca assumir sucesso.
- Proteção contra cliques duplicados em ações mutantes (desabilitar botão até
  resposta; idempotência no backend é a garantia real, a UI é camada de UX).
- Sem chaves/secret de serviços externos no cliente. O frontend só lida com
  dados que o backend autoriza a expor.