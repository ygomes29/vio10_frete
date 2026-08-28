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
| ADR-012 | Pricing engine determinístico (cotação, `draft → quoted`) | Aprovado (Sessão 07) |
| ADR-013 | Dispatch engine (busca de candidatos + raio progressivo, `quoted → searching_driver`) | Aprovado (Sessão 08) |
| ADR-014 | Bid engine (scoring + seleção + `claim_delivery` atômico, `searching_driver → assigned`) | Aprovado (Sessão 09) |

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

### Sessão 09 — Bid engine (scoring + seleção + `claim_delivery` atômico, ADR-014)

- **1 RPC system-only `select_winner_and_claim`** (D1, terceiro system-only após
  `create_quote`/`open_dispatch_round`): fecha a rodada, coleta candidatos válidos,
  pontua in-DB, escolhe vencedor determinístico, chama `claim_delivery` internamente
  (atômico). Sem vencedor → fecha a rodada + `no_candidates` (orquestrador abre a próxima
  rodada de raio maior). `BACKEND.md` §4 já previa `select_winner_and_claim`. Espelha o
  padrão system-only de `create_quote`/`open_dispatch_round`.
- **Scoring min-max + pesos de param** (D4): `bid_amount_cents` + distância PostGIS
  (`ST_Distance` `driver_locations.position` vs `pickup_point`); **ETA peso 0** até o
  RoutingProvider (Sessão 20) — distância como proxy operacional. Normalização min-max
  (`nullif` evita divisão por zero; fator constante → não diferencia → tie-break decide).
  `score = p_weight_price*(1-norm_bid) + p_weight_distance*(1-norm_dist)` (`numeric`
  adimensional, **não** dinheiro; dinheiro permanece `bigint` em `bid_amount_cents`).
- **Tie-break determinístico** (definido no ADR, não ditado por ADR-006): `score desc,
  dist_m asc, responded_at asc, driver_id asc`. Distância primeiro, depois rapidez de
  resposta, depois `driver_id` (estável entre runs). `now()` é constante numa transação →
  em testes single-tx o tie-break cai para `driver_id` asc; a ordem `responded_at` é
  exercitada em concorrência real na Sessão 10 (GATE).
- **Re-validação de eligibility no close** (D3): candidatos = offers respondidas
  (`accepted`/`counter_bid`) com driver ainda elegível (active+available+veículo
  compatível+sem assignment ativa+localização fresca+`ST_DWithin` no raio da própria
  rodada+offer não expirada). O driver que ACEITOU mas depois foi atribuído a outra
  corrida (race) é excluído — sua offer vira `lost` (R16) ou `expired` (no_candidates).
  Reusa a eligibility do `open_dispatch_round` (0023:201-217) verbatim, a partir das
  offers respondidas.
- **Sem coluna de winner** (D6): o vencedor vive em `delivery_assignments` (linha
  `active`) + `delivery_offers.status='won'` + `delivery_events` (`winner_selected` com
  scores de todos os candidatos no `metadata` — rastro **explicável**). **Sem `winner_*`
  em `dispatch_rounds`**. **Nenhuma tabela/coluna nova.**
- **Sem early-close arbitrária no MVP** (D5, ADR-006): o MVP espera o timeout da janela;
  o orquestrador chama `select_winner_and_claim` no close. Early close futuro só por regra
  determinística explícita (ex.: `candidate_score >= fast_accept_threshold`), nunca
  "primeiro que aceitar ganha".
- **System-only / trust boundary** (D1): pesos de scoring vêm do backend (config do
  orquestrador), não do business — um business passando pesos forjaria o vencedor. Grants:
  `revoke public` + `execute` só a `service_role` (`authenticated` sem EXECUTE — defesa em
  profundidade); `anon`: nada. Idempotência por estado: rodada já `closed` →
  `round_not_open`.
- **Raio progressivo** (D2): orquestrador chama `open_dispatch_round` (raio maior) +
  `select_winner_and_claim` (fecha + tenta atribuir) repetidamente. Sem vencedor →
  próxima rodada; com vencedor → `assigned`, fim do dispatch.
- **GATE (Sessão 10)**: atomicidade de `claim_delivery` testada funcionalmente (exatamente
  1 assignment ativo, `already_assigned` no pós-race); o harness de **concorrência real**
  (dois `select_winner_and_claim`/`claim_delivery` paralelos via `dblink`/advisory lock) é
  o gate formal de produção (ADR-007).
- **Sem novos grants de DML a `authenticated`; sem tabela nova** (D8): único grant novo
  = `execute on select_winner_and_claim to service_role`. `dispatch_rounds`/
  `delivery_offers`/`bids` já têm RLS SELECT (0017) + `service_role` DML (0015).

### Sessão 08 — Dispatch engine (busca de candidatos + raio progressivo, ADR-013)

- **2 RPCs, 2 trust boundaries** (ADR-013 D1/D2): `confirm_quote` (user-scoped,
  membro da org/operator/admin/system) confirma a cotação; `open_dispatch_round`
  (system-only, segundo system-only após `create_quote`) abre cada rodada. Componível:
  o orquestrador chama `open_dispatch_round` N vezes (raio progressivo). Alinha a "Backend
  decide, n8n orquestra".
- **`confirm_quote` user-scoped** (D1): authz system/`is_platform_admin()`/membro da org;
  valida `quoted` + quote `pending` não expirada; **transition-first** `quoted→
  searching_driver` (emite `dispatch_started`, seta `dispatch_started_at`); se ok, marca
  quote `confirmed`+`confirmed_at`, emite `quote_confirmed`. Se a transição falhar, retorna
  sem marcar (sem órfã). Idempotência por estado: re-confirmar → `wrong_state`. Grants:
  `service_role` + `authenticated` (user-facing); `anon`: nada.
- **`open_dispatch_round` system-only** (D2): `auth.uid() IS NOT NULL` → `not_authorized`.
  Trust boundary: raio/candidatos/oferta são insumos do orquestrador (backend), não do
  business — um business passando `p_search_radius_m`/`p_driver_offer_cents` forjaria a
  busca/oferta. Grants: `service_role` **somente** (`authenticated` sem EXECUTE — defesa em
  profundidade); `anon`: nada. Espelha `create_quote`.
- **Parâmetros do caller (backend), sem tabela de config** (D2/D5): `open_dispatch_round`
  recebe raio/max_candidates/driver_offer/janela/max_location_age como params do backend
  (que lê config própria). `dispatch_config` table **adiada** no MVP. Raio progressivo é
  **orquestrado** (D5): o RPC abre uma rodada por chamada; a sequência crescente de raios e
  o limite de rodadas/raio máximo são do orquestrador (Sessões 13-14); `round_number`
  monotônico por corrida; guard `round_already_open`.
- **Eligibility MVP** (D3): `active` + `available` + `current_vehicle_id` compatível
  (`vehicle_type = vehicle_required`) + sem assignment ativa + localização fresca
  (`captured_at > now() - max_age`) + `ST_DWithin` no raio (geography, metros — proximidade
  operacional, **não** cobrança; distinto de pricing). Ordenação `ST_Distance` ASC,
  `LIMIT max_candidates`. **Filtro `service_areas` por entregador ADIADO** (sem junction
  driver↔area; raio até a coleta é a única restrição espacial). **Capacidade/peso/dims
  ADIADO** (só `vehicle_type`; `weight_g`/dims no scoring futuro). **`offered` reservado**:
  não muta `current_availability_status` ao criar offers; driver permanece `available`,
  pode receber offers de rodadas distintas; guard contra dupla offer na mesma rodada é o
  UK `(dispatch_round_id, driver_id)`.
- **Atomicidade** (D4/D6): `open_dispatch_round` cria `dispatch_round` + todas as offers
  numa transação — se qualquer offer insert falhar, rollback (sem rodada órfã). Cria a
  rodada **mesmo com 0 candidatos** (audit snapshot; orquestrador expande o raio). Emite
  `round_opened` + `offer_created` (ator `'system'`). Sem `idempotency_key`/
  `external_reference` (idempotência por estado, ADR-012 D8).
- **Ator via `auth.uid()`** (D7): `confirm_quote` → system=`'system'`, admin=`'admin'`,
  membro=`'business'`; `open_dispatch_round` → sempre `'system'`. Nunca de param.
- **Sem novos grants de DML a `authenticated`; sem tabela nova** (D8): `dispatch_rounds`/
  `delivery_offers` já têm RLS SELECT (0017) + `service_role` DML (0015). `authenticated`
  mantém SELECT sob RLS + EXECUTE em `confirm_quote`. Único grant system-only novo:
  `execute on open_dispatch_round to service_role`. **Nenhuma tabela/coluna nova.**

### Sessão 07 — Pricing engine determinístico (ADR-012)

- **`create_quote` é system-scoped apenas (primeiro RPC system-only)** (ADR-012 D1):
  `auth.uid() IS NOT NULL` → `not_authorized`. Só o backend (`service_role`) chama.
  **Trust boundary:** distância/duração são **insumos do cálculo** vindos do provider
  de rota (plataforma, Sessão 20), não do business — um business autenticado passando
  `p_distance_meters` forjaria distância pequena → preço baixo. Grants: `revoke public`
  + `execute` só a `service_role` — `authenticated` **nem EXECUTE** recebe (defesa em
  profundidade: bloqueio no nível de privilégio antes da checagem interna de
  `auth.uid()`); `anon`: nada. Distinto de `create_delivery_request` (permite membro de
  org): endereços são do business; a distância é da plataforma.
- **Álgebra determinística** (ADR-012 D2, do exemplo do doc): `customer_price =
  subtotal + platform_fee`; `driver_offer = subtotal − platform_fee`; margem plataforma
  = `2 × platform_fee` (fee dos dois lados). `distance_component = (per_km_cents ×
  meters + 999) / 1000` (ceil inteiro, **sem float**). `vehicle_component` e
  `dynamic_component` = **0 no MVP** (custo do veículo codificado pela seleção da regra
  por `vehicle_type`; demanda/pico deferido). `subtotal = greatest(raw, min_price_cents)`
  (piso do subtotal). `driver_offer < 0` → `pricing_error` (regra mal-config).
- **Faixa min/max real** (ADR-012 D3): `pricing_rules` +`min_multiplier`/`max_multiplier`
  numeric(5,4) default 1.0. `delivery_quotes` +`min/max_customer_price_cents`/`min/max
  _driver_offer_cents`. `min_customer = greatest(min_price, floor(customer×min_mult))`;
  `max_customer = ceil(customer×max_mult)`; análogo p/ driver. Default 1.0/1.0 → faixa
  degenerada; orgs configuram banda real (ex.: 0.90/1.10). `customer_price`/`driver_offer`
  = alvo determinístico; min/max = faixa exibida ao business / banda de lances.
- **Seleção de regra org → global fallback** (ADR-012 D4): regra da org (mesmo
  `vehicle_type`, ativa, `effective_from ≤ now`) → fallback global
  (`organization_id is null`) → `no_pricing_rule`.
- **Atomicidade transition-FIRST** (ADR-012 D5): `create_quote` chama
  `transition_delivery('quoted')` **antes** de insertar `delivery_quotes`; se a transição
  falhar (ex.: `wrong_state` em race), retorna **sem** insertar (sem quote órfã). Tudo
  numa transação DEFINER.
- **TTL/estado/idempotência** (ADR-012 D7/D8): `expires_at = now()+900s`, `status=
  'pending'`. `confirmed_at`/`confirmed` é setado em `quoted→searching_driver` (Sessão
  08), não aqui. Re-cotar corrida já `quoted` → `wrong_state` (idempotência por estado,
  sem `idempotency_key`/`external_reference`).

## Decisões ainda em aberto (a resolver nas próximas sessões)

- Hospedagem final do n8n (self-host confirmado; infra específica na Sessão 13).
- Detalhes do modelo financeiro (Sessão 21 — desenhar antes de implementar).
- Limites concretos do piloto (Sessão 26).
- Provider geocoder secundário (Nominatim/Mapbox) se custo do Google justificar
  (Sessão 20).

## Como propor nova decisão

Toda decisão arquitetural relevante vira um novo ADR em `docs/adr/` (número
sequencial) e é listada aqui. Não decidir arquitetura em conversa sem registro.