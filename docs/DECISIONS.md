# docs/DECISIONS.md — Log consolidado de decisões

> Decisões arquiteturais formais. Cada uma tem um ADR correspondente em
> `docs/adr/`. Este arquivo é o índice legível; os ADRs são o registro detalhado.

## Status

Aprovadas na Sessão 02 (2026-08-27).

## Índice de ADRs

| ADR | Decisão | Status |
|---|---|---|
| ADR-001 | Banco (Postgres/Supabase) como fonte da verdade | Aprovado |
| ADR-002 | Backend dentro do Next.js no MVP (Route Handlers + serviços + RPC) | Aprovado |
| ADR-003 | Supabase como plataforma de dados/auth/storage/realtime | Aprovado |
| ADR-004 | n8n somente como orquestrador (não fonte da verdade) | Aprovado |
| ADR-005 | Google Maps atrás de provider abstraction (TWO_WHEELER) | Aprovado |
| ADR-006 | bidding round antes da atribuição (ACEITAR ≠ GANHAR) | Aprovado |
| ADR-007 | Atribuição atomicamente protegida pelo banco | Aprovado |
| ADR-008 | Valores financeiros em centavos inteiros | Aprovado |
| ADR-009 | Matriz RBAC (papel × recurso × ação) — escopo MVP | Aprovado (Sessão 04) |
| ADR-010 | Ciclo de vida de identidade e autenticação (MVP) | Aprovado (Sessão 05) |
| ADR-011 | Criação da corrida + gestão de entidades (empresas/veículos/entregadores) | Aprovado (Sessão 06) |

## Decisões adicionais registradas (sem ADR próprio, mas vinculadas)

- **Tenancy**: `organization → business → business_location`.
- **Estados da corrida**: `bidding` não é estado principal; disputa dentro de
  `searching_driver`.
- **Localização do entregador**: ~10s em foreground; conceito de `stale`; app
  nativo só se justificar.
- **Frontend**: 3 superfícies em 1 codebase Next.js (route groups); nunca inventa
  estado.
- **Server Actions**: só para ações originadas no frontend; n8n/DataCrazy não
  dependem delas.
- **Idempotência**: `idempotency_key` + `external_event_id`; retries são normais.
- **Observabilidade**: `correlation_id` + contexto por evento crítico.
- **Next.js**: 16.3.3 Active LTS (não 15); confirmar patch mais recente ao inicializar.

## Decisões adicionais da Sessão 03.5 (validação, 2026-08-28)

- **PostGIS em schema `extensions`**: `geography`/`ST_*` ficam em `extensions` (não em
  `public`), para não poluir `public`. Migrations que usam PostGIS declaram
  `set search_path to public, extensions;` (o runner de migrations/testes não inclui
  `extensions` no search_path padrão).
- **Grants default-deny total (0014)**: além de RLS default-deny, revoga-se
  explicitamente de `anon`/`authenticated`/`service_role` (existentes + `ALTER
  DEFAULT PRIVILEGES FOR ROLE postgres`) porque o Supabase auto-concede a esses roles
  via default privileges. Grants finais (least-privilege por função/tabela) na Sessão 04.
- **R16 — perdedoras cross-round**: após a atribuição oficial, TODAS as offers ainda
  respondíveis da corrida inteira (em qualquer rodada) viram `lost` — `claim_delivery`
  filtra por `delivery_request_id`, não por rodada. Escopo é a corrida, não a rodada.
- **R17 — `external_reference` ≠ `idempotency_key`**: conceitos distintos (vínculo
  externo vs retry de operação); ver `docs/SECURITY.md`.
- **`service_role` user-scoped vs system-scoped**: operações de usuário rodam
  user-scoped (`authenticated`, RLS aplica); operações do sistema rodam system-scoped
  (`service_role`, bypass). `service_role` nunca vaza para integradores externos. Ver
  `ARCHITECTURE.md` §3.1. (Sessão 04 reverteu "RPCs SECURITY INVOKER" para **Modelo B**:
  RPCs user-facing `SECURITY DEFINER` + checagem de `auth.uid()` — `0016`, ADR-009.)
- **pgTAP server-side sem Docker**: runner próprio (temp table `_tap` + `num_failed()`
  + `begin/rollback` clean-slate) para executar testes via Management API quando Docker
  está ausente.

## Decisões adicionais da Sessão 05 (auth/identidade, 2026-08-28)

- **Auth method MVP = email + senha** (ADR-010 D1). phone/OTP e magic-link adiados para
  o frontend (Sessões 17-19). `enable_anonymous_sign_ins = false`; senha forte (12,
  lower/upper/digits/symbols) em `config.toml`.
- **Criação de perfil via trigger `handle_new_user`** (ADR-010 D2, 0018): trigger
  `SECURITY DEFINER` on `auth.users` AFTER INSERT cria row em `profiles`
  (`on conflict do nothing`). Garante FK de `user_platform_roles`/
  `organization_memberships`/`drivers` → `profiles(id)`. O trigger **não** atribui
  papel/membership/driver (ato explícito via 0019). Padrão Supabase.
- **Convites via `invitations` + `accept_invitation`** (ADR-010 D3, 0019): `anon` **não**
  acessa — `accept_invitation` exige caller autenticado cujo email casa com o convite
  (prova propriedade do email via login). Aplica papel idempotente (`on conflict do
  nothing`); aceitar 2x → `already_accepted` (não duplica).
- **`is_platform_admin()` ≠ `is_super_or_admin()`** (ADR-010 D4.1, 0019): visibilidade
  (RLS) inclui `operator` (despacho cross-tenant, ADR-009); autoridade de **mutação**
  (atribuir papel, criar driver, cancelar convite alheio) é `super_admin`/`admin` só
  (helper `is_super_or_admin`). Reusar `is_platform_admin()` em mutação seria escalonamento
  de privilégio do `operator`.
- **JWT DB-lookup, sem custom claims** (ADR-010 D5): helpers `is_platform_admin`/
  `my_org_ids`/`my_driver_id` resolvem o caller; nada em `auth.hook.custom_access_token`.

## Decisões adicionais da Sessão 06 (criação da corrida, 2026-08-28)

- **Criação = `draft` + itens + evento `delivery_created`, sem preço** (ADR-011 D1):
  `create_delivery_request` insere `delivery_requests` (`status='draft'`) +
  `delivery_items` + um `delivery_events` (`delivery_created`) numa transação. Nenhuma
  cotação — pricing (cotação, `draft → quoted`) é **Sessão 07** (motor determinístico
  escreve `delivery_quotes`). Confirmado por `PRODUCT.md` (criação ≠ cálculo de preço),
  `DELIVERY_LIFECYCLE.md` (`draft → quoted` autorizado a sistema/pricing) e o schema
  (`delivery_requests` não tem colunas de preço; preço vive em `delivery_quotes`).
- **Snapshots auto-contidos; ponto montado server-side** (ADR-011 D2): pickup/delivery
  passados explicitamente (address + lat/lng + `contact_phone` obrigatórios);
  `business_location_id` é link soft (nullable, on delete set null) — o snapshot é a
  verdade. O `geography(Point,4326)` é montado server-side via
  `ST_SetSRID(ST_MakePoint(lng,lat),4326)::geography` (caller nunca envia o point);
  mantém o invariante `point ↔ (lat,lng)` e centraliza PostGIS (schema `extensions`).
- **`external_reference` = dedup de criação (NÃO retry)** (ADR-011 D3): se informado e
  já existir `(organization_id, external_reference)` → `already_exists` com id
  existente (`ok=true`, idempotente). É dedup do vínculo externo (uma org não cria duas
  corridas para o mesmo pedido externo), **não** chave de retry. Retries de
  API/integration ficam com `integration_events.idempotency_key` (Sessão 13). Ver R17.
- **Matriz de autoridade de gestão** (ADR-011 D4, estende ADR-009):
  `create_organization`=super/admin; `create_business`=super/admin ou business_owner
  da org; `create_business_location`=business_owner da org do business ou admin;
  `create_vehicle`=**driver self** ou super/admin (veículos driver-owned);
  `set_current_vehicle`=driver dono ou admin; `update_driver_status`=super/admin
  (sem system — mutação de identidade, alinha a 0019); `create_delivery_request`=
  membro da org ou `is_platform_admin()` (admin/operator), **system path permitido**
  (api/integration/whatsapp).
- **`vehicles.plate` unique** (0020): placa fisicamente única; `create_vehicle`
  idempotente via `on conflict (plate) do nothing` → `already_exists`.
- **Mutação só via RPC DEFINER** (ADR-011 D5): nenhuma policy INSERT/UPDATE/DELETE para
  `authenticated` em organizações/businesses/locations/vehicles/delivery_requests (RLS
  SELECT já existe em 0017). Apenas grants EXECUTE são adicionados. `anon`: nada.
- **Capture de ator** (ADR-011 D6): system path → `actor_type='system'`; platform admin
  → `'admin'`; membro de org → `'business'`. `actor_id = auth.uid()` quando presente.
  Alinha com `transition_delivery` (ator deriva de `auth.uid()`, nunca de params).
- **Offboarding parcial** (0020 `update_driver_status`): ativa/suspende/bloqueia driver
  (`account_status` ∈ active/suspended/blocked; não volta a `pending`) — fecha o lado
  driver do risco "revogação" em aberto desde a Sessão 05. `remove_platform_role`/
  `remove_org_member` (revogação de papel/membership) ainda deferidos.

## Decisões ainda em aberto (a resolver nas próximas sessões)

- Hospedagem final do n8n (self-host confirmado; infra específica na Sessão 13).
- Detalhes do modelo financeiro (Sessão 21 — desenhar antes de implementar).
- Limites concretos do piloto (Sessão 26).
- Provider geocoder secundário (Nominatim/Mapbox) se custo do Google justificar
  (Sessão 20).

## Como propor nova decisão

Toda decisão arquitetural relevante vira um novo ADR em `docs/adr/` (número
sequencial) e é listada aqui. Não decidir arquitetura em conversa sem registro.