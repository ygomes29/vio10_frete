# ADR-023 — PWA Entregador (read-side sem RPC, polling, login Server Action, manifest+SW)

- **Status**: Aprovado
- **Data**: 2026-08-31
- **Sessão**: 17

## Contexto

A Sessão 15 (ADR-020) fechou a contract surface **write-side** do driver
(`respond_to_offer`, `submit_proof_of_delivery`, `transition_delivery` driver path,
`set_driver_availability`) — todos validados live via `next dev`+curl com cookie JWT.
A Sessão 14 (ADR-019) entregou a camada system/internal. Mas o ViO10 ainda tinha
**zero UI** e **zero read-side**: nenhum `GET` handler existia no repo, e a superfície
do entregador (FRONTEND.md §3 — login → disponível → oportunidade → ACEITAR/LANCE →
corrida ativa → coleta/entrega → POD → histórico/ganhos) era a próxima do roadmap
(Fase 9) e a que destrava o uso real em campo.

A RLS já libera o driver a ler o próprio estado desde a Sessão 04
(`can_view_delivery_request`, `my_driver_id()`, `driver_loc_sel/ins/upd`), e
`driver_locations` é a única mutação direta histórica do `authenticated` (0015/0017).
Logo o read-side vai **direto via client user-scoped** — **sem RPC/enum/grant/migration
novo**, como a Sessão 15 (camada de aplicação pura).

**Restrição viva**: geo 501 (Sessão 20) bloqueia o fluxo `create_quote`→dispatch
end-to-end. A validação live do PWA usa **fixture SQL** (offer/assignment injetados) +
mutações nos endpoints já provados — não se simula PASS do dispatch chain (regra mestra).

### Decisões do usuário (AskUserQuestion / plano aprovado)

- **Estilização**: Tailwind CSS v4 + shadcn/ui hand-rolled (primitivas `cva`+`cn`).
  FRONTEND.md manda shadcn/ui; hand-rolled por compatibilidade Next 16/React 19/Tailwind v4.
- **Live updates**: **polling** (GET a cada 10s). Realtime adiado (evita client Supabase
  no browser + auth Realtime). **Nenhum client Supabase no browser** — login via Server
  Action server-side; leitura/escrita por Route Handlers same-origin (cookie).
- **POD foto**: **adiada**. Storage RLS comportamental não foi live-validado (Sessão 12).
  MVP usa POD por **OTP (delivery) + notes (pickup)** — ambos válidos pelo
  `validatePodBody` sem `storage_path`. Upload de foto → Sessão 19/22.

## Decisões

### D1 — Read-side sem RPC: leitura direta via RLS (user-scoped)

- Os 5 endpoints GET (`/api/driver/me`, `/opportunity`, `/deliveries/active`,
  `/deliveries/history`, `/earnings`) fazem **queries diretas** via client user-scoped
  (`createServerClient`, cookie JWT, `auth.uid()`, RLS aplica). Sem RPC, sem view, sem
  migration. A única exceção histórica de mutação direta do `authenticated` —
  `driver_locations` (telemetria, 0015/0017) — é usada em `POST /api/driver/location`.
- Novo `handleUserGet` (espelho do `handleUserPost` sem parse de body): `getUser`→401
  se null → `run(correlationId, url, ctx)` → `toApiResponse`. `url` repassado p/
  `searchParams` (ex.: `?limit=`). Sem idempotency ledger (D7 ADR-020).
- Service layer `lib/services/driver-reads.ts`: cada fn retorna `RpcResult`-shaped
  (`{ok:true,reason:null,...payload}` / `{ok:false,reason}`) p/ fluir pelo handler.
  `resolveDriverId` (de `auth.uid()`) → `not_authorized` (403) se não for driver.

### D2 — Polling > Realtime no MVP

- Atualizações de estado por **polling** (10s, foreground) nas páginas relevantes
  (`OpportunityPanel`, `DeliveryStateMachine`). Evita um client Supabase no browser e
  a auth Realtime (complexidade de canal+token). Mutação e leitura por Route Handlers
  same-origin (cookie). Realtime → futura (whatsapp/n8n já notificam o driver).
- A UI reflete **estado oficial do backend** — se o sistema mover a corrida para
  `delivered` (após `confirm_delivery`), o polling traz a mudança; o frontend **não**
  inventa a transição (regra mestra / FRONTEND.md §2).

### D3 — Login via Server Action + redirect por role

- `app/auth/login/actions.ts` (`"use server"`): `signIn(prev, formData)` chama
  `signInWithPassword` no client server-side (`createServerClient`, `setAll` escreve
  cookie na Server Action), depois `resolveLandingPath(client)` consulta
  `user_platform_roles`→`/admin`, `drivers`→`/driver`, `organization_memberships`→
  `/business`. Sem role → `signOut` + mensagem. `signOut` → redirect `/auth/login`.
- Form client usa `useActionState<SignInState, FormData>`. **Nenhum client Supabase no
  browser** nesta sessão — toda auth é server-side (cookie httpOnly).

### D4 — PWA: manifest + service worker + route group `(driver)`

- `app/manifest.ts` (MetadataRoute.Manifest): name `ViO10 Entregador`, `start_url
  /driver`, `display standalone`, icons SVG (any + maskable). `app/layout.tsx` metadata
  (lang pt-BR, `appleWebApp`, `viewport` com `themeColor`, `userScalable:false`,
  `viewportFit:cover` p/ notch).
- `public/sw.js` (network-first navegação, no `/api/*` caching,
  stale-while-revalidate statics, `CACHE vio10-shell-v1`) registrado por
  `<PWARegister/>` (`navigator.serviceWorker.register('/sw.js')` — SW em
  `public/` é servido na raiz, padrão doc Next 16).
- Route group `app/(driver)/...` → URL `/driver/...` (parênteses não afetam URL).
  `app/(driver)/layout.tsx`: header (logo + Histórico + Logout) + PWARegister + main
  `max-w-2xl` + safe-area padding. Middleware (Sessão 15) protege `/driver` → 307
  `/auth/login?redirect=`.

### D5 — POD por OTP (delivery) + notes (pickup); foto adiada

- O `DeliveryStateMachine` (client) submete POD via `POST /api/driver/deliveries/{id}/pod`
  (Sessão 15): **pickup** = `notes` (gate p/ `picked_up`, ADR-017 D3); **delivery** =
  `receiver_name` + `otp_code` (o recebedor recebeu via WhatsApp). Foto/storage_path
  omitido — válido pelo `validatePodBody`. Upload de foto (bucket `pod-photos`, RLS
  Sessão 12) → Sessão 19/22.
- **Submete POD ≠ entregue** (análogo a ACEITAR ≠ GANHAR, ADR-017): o driver **não**
  marca `delivered`. O `submit_proof_of_delivery` emite `pod_submitted`; a transição
  `delivered` é **system** via `confirm_delivery` (valida POD + OTP + geo). A UI mostra
  "Aguarde — o sistema está confirmando" após o POD e o polling traz `delivered`.

### D6 — Sem migration/RPC/enum/grant novo

- Como a Sessão 15, é camada de aplicação pura. Os 4 RPCs driver-facing são finais
  desde Sessões 09-12. RLS já libera o read-side. `driver_locations` upsert é direto
  (RLS `driver_id = my_driver_id()`). **Nenhuma migration** nesta sessão.

### D7 — Frontend só apresenta estado oficial, nunca inventa

- Server Components (`/driver`, `/driver/delivery/[id]`, `/driver/history`) leem estado
  via `getDriverContext()` + `driver-reads` (RLS, cookie) e passam **estado oficial** aos
  client components. Client components só mutam via Route Handlers (RPC) e leem via
  polling. Nenhum estado de corrida é derivado/inventado no client — a fonte da verdade
  é o banco (regra mestra / FRONTEND.md §2).

### D8 — Localização só em foreground

- `useDriverLocation(enabled, intervalMs=10s)`: `navigator.geolocation.watchPosition`
  → POST `/api/driver/location` apenas quando `enabled` (corrida ativa) **E**
  `document.visibilityState==='visible'` (foreground). Não presume rastreamento
  confiável em background — tracking persistente exigiria app nativo (GEOLOCATION.md).
  Rate-limited (~10s); heartbeat reenvia leitura pendente não-enviada.

### D9 — Validação fixture-based (geo 501 bloqueia fluxo completo)

- O fluxo dispatch completo (quote→searching→offer→assigned) **não é validado live**
  (geo 501, Sessão 20). A UI é exercitada via **fixture SQL** (offer `status='pending'`
  + assignment ativa + delivery em `assigned` injetados) + mutações nos endpoints já
  provados (Sessão 15). Não se simula PASS do dispatch chain (regra mestra).

## Consequências

- Read-side driver completo sem tocar o schema (D1/D6). Regra mestra íntegra: frontend
  só apresenta; `service_role` nunca vaza ao client (client user-scoped, cookie JWT).
- PWA instalável (D4); login real por role (D3); polling traz estado oficial (D2/D7).
- POD foto e Realtime ficam como dívida observada (D5/D2). Validação live do dispatch
  chain fica para quando o geo provider sair do 501 (Sessão 20) — D9.

## Ressalvas (regra mestra — não simulado PASS)

- Dispatch chain completo não validado live (geo 501, Sessão 20) — UI via fixture SQL.
- POD foto / Storage RLS comportamental → Sessão 19/22.
- Realtime → futura (polling no MVP).
- UI admin (Sessão 18) / portal business (Sessão 19) fora desta sessão.