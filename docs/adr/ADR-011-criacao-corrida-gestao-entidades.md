# ADR-011 — Criação da corrida + gestão de entidades (empresas/veículos/entregadores)

- **Status**: Aprovado
- **Data**: 2026-08-28
- **Sessão**: 06

## Contexto

A Sessão 05 entregou o ciclo de vida de identidade/auth (0018/0019). A fundação de
banco (Sessão 03/03.5) já criou **todas as tabelas** que a criação da corrida precisa:
`organizations`, `businesses`, `business_locations` (0004); `drivers`, `vehicles` (0005);
`delivery_requests`, `delivery_items` (0007); `delivery_events` (0010); `delivery_quotes`
(0008). Mas falta o **contrato de mutação**:

- Nenhum RPC cria `organizations`/`businesses`/`business_locations` — e
  `delivery_requests.organization_id`/`business_id` são `NOT NULL`, então **nenhuma
  corrida pode nascer** sem antes existir o tenant. Há um bootstrap: para convidar um
  `business_owner` (0019 `create_invitation` exige `organization_id`), a org precisa
  existir antes. Sem `create_organization`, o onboarding trava.
- Nenhum RPC cria `vehicles`. Drivers são platform-scoped e `vehicles.driver_id` NOT
  NULL (veículo pertence a um driver); sem `create_vehicle`, o entregador não registra
  moto/carro — necessário ao dispatch (Sessão 08).
- `create_driver` existe (0019), mas não há como **ativar/suspender/bloquear** um driver
  (`drivers.account_status` fica em `pending` para sempre). O risco "offboarding/
  revogação" ficou em aberto desde a Sessão 05.
- Nenhum RPC cria `delivery_requests`. A corrida (núcleo do produto) não tem ponto de
  entrada transacional que respeite tenancy, snapshots, idempotência e auditoria.

Sessão 06 é a **fase de criação** (Fase 2 do roadmap). Entrega o contrato DB de gestão de
entidades + criação da corrida em `draft`. Pricing (cotação, `draft → quoted`) é
**Sessão 07**; dispatch (busca de candidatos, `service_areas`) é **Sessão 08**.

### Por que `draft` (sem preço)
- `docs/PRODUCT.md` (fluxo macro) separa criação (passos 1–2) de cálculo de preço (passo 3).
- `docs/DELIVERY_LIFECYCLE.md`: `draft → quoted` é autorizado a "sistema (pricing)".
- `docs/PRICING_ENGINE.md` é referência da Sessão 07.
- Schema: `delivery_requests` **não tem colunas de preço**; preço vive em `delivery_quotes`
  (0008); `quoted_at` é preenchido só na transição `draft → quoted`.

## Decisões

### D1 — Criação da corrida = `draft` + itens + evento `delivery_created`; sem preço

`create_delivery_request` insere, numa transação: `delivery_requests` (`status='draft'`),
`delivery_items` (1:N), e um `delivery_events` (`event_type='delivery_created'`,
`from_status=null`, `to_status='draft'`). Nenhuma cotação, nenhum `delivery_quotes`. O
preço é calculado pela Sessão 07 (motor determinístico), que escreve a quote e dispara
`draft → quoted` via `transition_delivery`.

- **Ator capturado no evento** (D6): system → `'system'`; platform admin → `'admin'`;
  membro de org → `'business'`; `actor_id = auth.uid()` quando presente.
- `correlation_id` propagado (parâmetro) para rastreabilidade ponta-a-ponta.

### D2 — Snapshots auto-contidos; ponto montado server-side

pickup/delivery são passados **explicitamente** (address + lat/lng + `contact_phone`
obrigatórios; `contact_name` opcional). O `business_location_id` é só um **link soft**
(nullable, `on delete set null`); o **snapshot** é a verdade — a corrida não muda se a
unidade for editada/deleted depois (consistente com o comentário do schema 0007:
"snapshots go to delivery_requests").

- O ponto `geography(Point,4326)` é **montado server-side** a partir de lat/lng
  (`ST_SetSRID(ST_MakePoint(lng,lat),4326)::geography`) — o caller **nunca** envia o point.
  Isto mantém o invariante `point ↔ (lat,lng)` e centraliza a construção PostGIS
  (lição Sessão 03.5: PostGIS vive no schema `extensions` → `set search_path` inclui
  `extensions`).

### D3 — `external_reference` = dedup de criação (NÃO retry)

Se `p_external_reference` for informado e já existir `(organization_id, external_reference)`
(constraint `delivery_requests_external_ref_uk`, 0007), a RPC retorna `(true,
'already_exists', <id existente>)` — idempotente, não duplica. Isto é **dedup do vínculo
externo** (uma org não cria duas corridas para o mesmo pedido externo), **não** chave de
retry. Retries de API/integration (mesma operação re-enviada) ficam com
`integration_events.idempotency_key` (Sessão 13). Ver `docs/SECURITY.md` R17 para a
distinção `external_reference` ≠ `idempotency_key`.

- `external_reference` pode ser `NULL` (corridas criadas direto no ViO10); o UNIQUE admite
  múltiplos NULLs (SQL padrão).

### D4 — Matriz de autoridade de gestão (estende ADR-009)

| RPC | Autorizado (user path) | System path |
|---|---|---|
| `create_organization` | `is_super_or_admin()` (provisionamento de tenant) | permitido (backend) |
| `create_business` | `is_super_or_admin()` **ou** `business_owner` da própria org | permitido |
| `create_business_location` | `business_owner` da org do business **ou** `is_super_or_admin()` | permitido |
| `create_vehicle` | **driver self** (`drivers.user_id = auth.uid()` de `p_driver_id`) **ou** `is_super_or_admin()` | permitido |
| `set_current_vehicle` | driver dono do veículo **ou** `is_super_or_admin()` | permitido |
| `update_driver_status` | `is_super_or_admin()` apenas | **negado** |
| `create_delivery_request` | membro da org (`organization_memberships`) **ou** `is_platform_admin()` (admin/operator) | **permitido** (api/integration/whatsapp) |

Justificativas:
- **`create_organization` = super/admin apenas**: criar um tenant é ato de plataforma
  (onboarding de cliente contratante). O primeiro `business_owner` entra via convite
  (0019) depois da org existir — `create_business` (super/admin) quebra o bootstrap.
- **`business_owner` gerencia businesses/locations da própria org**: delegação dentro
  do tenant (multi-unidade), consistente com ADR-009 (owner > user). `business_user` não
  cria unidades (apenas consome); pode criar corridas (D1).
- **`create_vehicle` = driver self ou admin**: veículos são **driver-owned**
  (`vehicles.driver_id` NOT NULL; drivers platform-scoped). O entregador registra a própria
  moto no PPA (Sessão 17); admin pode provisionar. `create_driver` (0019) é admin-only
  porque cria a **identidade**; veículo é posse do driver.
- **`update_driver_status` = super/admin, sem system**: ativa/suspende/bloqueia é mutação
  de **identidade** — alinhado a 0019 (mutação de identidade exige admin autenticado, sem
  system). Fecha o risco "offboarding" parcialmente (account_status cobre
  ativo/suspenso/bloqueado; revogação de papel/membership ainda deferida).
- **`create_delivery_request` aceita system path**: origens `api`/`integration`/`whatsapp`
  (Sessões 13/15–16) criam corrida via backend system-scoped. Dashboard (business/admin/
  operator) usa user path. `operator` (em `is_platform_admin()`) pode criar — despacho
  operacional pode abrir corrida manualmente.

### D5 — Mutação só via RPC `SECURITY DEFINER` (Modelo B)

Nenhuma policy de INSERT/UPDATE/DELETE para `authenticated` em
organizations/businesses/business_locations/vehicles/delivery_requests (RLS SELECT já
existe em 0017). Apenas grants `EXECUTE` são adicionados. `service_role` já tem DML total
(0015) e `EXECUTE` em tudo. `anon`: nada. Isto fecha bypass via PostgREST direto (igual à
Sessão 04): a única mutação user-facing é a RPC, que faz a checagem interna de `auth.uid()`.

### D6 — Capture de ator

system path (`auth.uid() IS NULL`) → `actor_type='system'`, `actor_id=null`. User path:
`is_platform_admin()` → `'admin'`; senão membro de org → `'business'`. `actor_id =
auth.uid()`. Alinhado com `transition_delivery` (0016), que deriva ator de `auth.uid()`
(nunca dos params).

## Consequências

- **0020** adiciona 6 RPCs DEFINER (gestão de empresas + veículos + status do driver) +
  índice unique em `vehicles(plate)` (placa fisicamente única; `create_vehicle` idempotente
  via `on conflict`).
- **0021** adiciona `create_delivery_request` (corrida em `draft` + itens + evento).
- Sem novas tabelas; sem novos grants de DML a `authenticated`; `anon` permanece sem nada.
- **Offboarding parcial**: `update_driver_status` (active/suspended/blocked) fecha o lado
  driver do risco em aberto; `remove_platform_role`/`remove_org_member` continuam deferidos
  (Sessão 06+ quando surgir o fluxo de offboarding completo).
- **Defesa em profundidade mantida**: criação de corrida é imposta no banco (RPC DEFINER
  valida tenancy) **e** no serviço (authz antes da RPC) — igual ao padrão de atribuição.
- `external_reference` como dedup fecha o problema "duas corridas para o mesmo pedido
  externo" no banco, independente do backend lembrar.

## Fora do escopo (adiado)

- **Pricing** (cotação, `delivery_quotes`, `draft → quoted`) → **Sessão 07**.
- **Dispatch** (busca de candidatos, `service_areas` management, raio progressivo) →
  **Sessão 08**. `service_areas` é platform-scoped (sem `org_id`) e consumido pela
  eligibility/preço — sua gestão fica com o dispatch.
- **`update_vehicle`/`delete_vehicle`**, **driver_documents** management (Storage/PPA) →
  Sessão 17 (PPA entregador) ou quando surgir o fluxo.
- **`remove_platform_role`/`remove_org_member`** (revogação de papel) → Sessão 06+;
  `update_driver_status` cobre o lado driver agora.
- **WhatsApp-origin creation** (DataCrazy) → Sessões 15–16 (a RPC já suporta system path).
- **Rate limiting de criação** → camada de serviço/API (Sessão 22, security review).
- **Cancelamento/edição de corrida** → Sessão 11–12 (máquina de estados); Sessão 06 só
  cria em `draft`.

## Referências

`ADR-009` (matriz RBAC), `ADR-010` (identidade/auth), `docs/DELIVERY_LIFECYCLE.md`
(`draft → quoted`), `docs/PRICING_ENGINE.md` (Sessão 07), `docs/SECURITY.md` (R17
`external_reference` ≠ `idempotency_key`), `docs/PRODUCT.md` (fluxo macro, tenancy),
`0004_identity_tenancy.sql`, `0005_drivers.sql`, `0007_delivery_core.sql`,
`0010_assignments_events.sql`, `0016_rpcs_security_definer.sql`, `0019_invitations_roles.sql`.