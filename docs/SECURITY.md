# docs/SECURITY.md — Segurança do ViO10

> Documento de referência. Security review pesado na Sessão 22; aqui ficam os
> princípios e regras desde o início.

## Princípios

1. **Defesa em profundidade**: RLS no banco + autorização na camada de serviço.
   Mesmo que a API falhe em checar, o banco bloqueia cross-tenant.
2. **Negar por padrão**: acesso só quando explicitamente autorizado por papel +
   tenant.
3. **Banco é a autoridade final** para atomicidade e isolamento.
4. **Sem segredo no cliente**: chaves de serviços externos só no backend/env.
5. **Idempotência** em toda mutação sensível.
6. **Auditoria**: toda alteração relevante em corrida gera `delivery_event`.

## Papéis (RBAC)

`super_admin`, `admin`, `operator`, `business_owner`, `business_user`, `driver`.

Cada papel tem definido o que pode: visualizar, criar, alterar, cancelar,
atribuir, consultar valores, acessar dados de **outras** organizações.

### Isolamento multiempresa

- **Um estabelecimento não acessa corridas/outro estabelecimento.**
- **Um entregador não altera dados de outro entregador.**
- Só funções autorizadas executam operações administrativas.

Implementação: `organization_id` em toda tabela de domínio + **RLS** + autorização
no serviço. Testado explicitamente (tentativas de acesso indevido) na Sessão 04/22.

## Auth

- **Supabase Auth** (server-side, cookie-based) para sessão.
- Frontend recebe só dados autorizados; tokens/cookies gerenciados pelo backend.

### Contextos de execução — `service_role` user-scoped vs system-scoped

Dois contextos distintos (ver `ARCHITECTURE.md` §3.1):

- **User-scoped** — backend executa **em nome de um usuário autenticado** (role
  `authenticated`, JWT do usuário). **RLS aplica** e filtra por `organization_id`/driver.
  Usado para toda ação originada por um usuário (motorista aceita offer, business cria
  corrida, admin consulta). O backend **não** troca para `service_role` aqui para furar
  RLS — isso seria buraco de autorização.
- **System-scoped** — backend executa **como a própria plataforma** (role `service_role`,
  bypass de RLS via `rolbypassrls`). Usado para lógica de sistema confiável: dispatch
  engine, scoring, `claim_delivery`, expiração scheduled, transições de sistema,
  eventos de auditoria do sistema.

Regras:

1. **`service_role` nunca vaza** para n8n, DataCrazy, IA ou qualquer integrador externo.
   Eles chamam endpoints do backend; o backend decide o contexto por operação.
2. **RPCs user-facing são `SECURITY DEFINER` com checagem interna de `auth.uid()`**
   (Modelo B, Sessão 04 — reverte o INVOKER da Sessão 03; ver ADR-009 e
   `0016_rpcs_security_definer.sql`). A RPC roda como owner (bypassa RLS) e valida
   posse do caller internamente: `auth.uid() IS NULL` → system-scoped, permitido;
   `auth.uid() IS NOT NULL` → user-scoped, valida `drivers.user_id`, membership da org
   ou `user_platform_roles`. **Motivo:** com INVOKER + grants de DML a `authenticated`,
   um motorista logado poderia `PATCH delivery_requests.status` via PostgREST direto,
   furando a máquina de estados. Com DEFINER + **sem** DML de domínio a `authenticated`,
   a única mutação user-facing é a RPC, que faz a checagem. `auth.uid()` funciona sob
   DEFINER (lê o JWT, não o role do DB).
3. **Grants least-privilege** desde a Sessão 04 (`0014` default-deny total + `0015`
   least-privilege): `service_role` DML em tudo + EXECUTE nas 4 RPCs; `authenticated`
   SELECT em 20 tabelas (sob RLS `0017`) + EXECUTE nas 3 RPCs user-facing +
   INSERT/UPDATE só em `driver_locations`; `anon` nada. Mutação de domínio user-facing
   nunca por DML direto — só via RPC.
4. **Promoção proibida**: uma ação iniciada por usuário roda user-scoped. O backend não
   a "promove" a system-scoped para contornar RLS. Se o usuário não teria direito via
   RLS, o backend também não concede.
5. **RPCs system-only** (`create_quote` Sessão 07 ADR-012 D1; `open_dispatch_round`
   Sessão 08 ADR-013 D2; `select_winner_and_claim` Sessão 09 ADR-014 D1; `confirm_delivery`
   Sessão 11 ADR-016 D4; `generate_delivery_otp` Sessão 12 ADR-017 D1): RPCs que **não
   aceitam caller autenticado de forma alguma** — `auth.uid() IS NOT NULL` →
   `not_authorized`. `revoke all from public` + `grant execute to service_role`
   **somente**: `authenticated` **nem EXECUTE** recebe (defesa em profundidade — bloqueio no
   nível de privilégio antes da checagem interna de `auth.uid()`); `anon`: nada. **Trust
   boundary dos insumos de pricing** (`create_quote`): distância/duração são do provider de
   rota (plataforma, Sessão 20), não do business — um business passando `p_distance_meters`
   forjaria distância pequena → preço baixo. **Trust boundary dos insumos de dispatch**
   (`open_dispatch_round`): raio/max_candidates/driver_offer/janela são do orquestrador
   (backend), não do business — um business passando `p_search_radius_m`/
   `p_driver_offer_cents` forjaria a busca/oferta. **Trust boundary dos pesos de scoring**
   (`select_winner_and_claim`): os pesos de scoring vêm do backend (config do orquestrador),
   não do business — um business passando `p_weight_price`/`p_weight_distance` forjaria o
   vencedor. **Trust boundary do POD** (`confirm_delivery`): a confirmação da entrega é ato
   do sistema (valida o POD + transita `delivered`), não do driver — o driver submete a
   evidência (`submit_proof_of_delivery`, driver-scoped); o sistema confirma. **Trust
   boundary da geração do OTP** (`generate_delivery_otp`, Sessão 12): o código de
   verificação do recebedor é gerado pelo sistema e devolvido **só** ao caller system — o
   backend o encaminha via WhatsApp ao `delivery_contact_phone`; o driver **não** vê o código
   antes do recebedor (um driver gerando o OTP veria o código e poderia forjar a "verificação"
   do recebedor). Em produção, **n8n** chama `confirm_delivery` (webhook sobre
   `pod_submitted`); pré-n8n, o backend/service layer. O dashboard "solicitar cotação"/"abrir
   despacho"/"fechar rodada"/"confirmar entrega"/"gerar OTP" chama um Route Handler do
   backend, que chama a RPC system-scoped (Sessão 18). Distinto de
   `create_delivery_request`/`confirm_quote`/`submit_proof_of_delivery` (aceitam membro de
   org/driver): os endereços da corrida são do business; a distância, os insumos de dispatch,
   os pesos de scoring, a confirmação de entrega e o OTP do recebedor são da plataforma.

### Auth de usuários — identidade, convite e atribuição de papel (Sessão 05, ADR-010)

- **Método de auth MVP**: email + senha (Supabase Auth, cookie-based server-side).
  `enable_anonymous_sign_ins=false`; senha forte (`minimum_password_length=12`,
  `lower_upper_letters_digits_symbols` em `config.toml`). Telefone/OTP e magic-link
  **adiados** para a fase de frontend (Sessões 17-19); a camada DB de convites/papéis
  é idêntica nos três métodos, então adiar não gera retrabalho. UI de auth (`@supabase/ssr`,
  cookie wiring, telas por superfície) fica para as Sessões 17-19; nada no banco depende.
- **Criação de perfil via trigger** (`handle_new_user`, 0018): `SECURITY DEFINER` on
  `auth.users` AFTER INSERT → `profiles` (`on conflict do nothing`). **Garante a FK**
  de `user_platform_roles`/`organization_memberships`/`drivers` → `profiles(id)` em
  todo caminho (signup, convite aceito, provisionamento admin). O trigger **não**
  atribui papel — ato explícito via 0019.
- **Convite exige login (`anon` não acessa)**: `accept_invitation(p_token)` só roda
  para um caller **autenticado** cujo email casa com `invitations.email`. A prova de
  propriedade do email vem do login (Supabase Auth confirmou). Sem login, sem aceitar.
  `anon` não recebe grants em `invitations` nem `EXECUTE` em `accept_invitation` —
  bloqueado no nível de privilégio (defesa em profundidade **antes** da checagem
  interna de `auth.uid()`).
- **Idempotência de aceitar**: `accept_invitation` aplica o papel com
  `on conflict do nothing` (`user_platform_roles`/`organization_memberships`; driver
  via insert em `drivers` com `on conflict (user_id) do nothing`). Aceitar 2x →
  `already_accepted`, **não duplica** memberships nem reabre o convite. Respeita a
  regra de idempotência da regra mestra (§ Idempotência abaixo).
- **Visibilidade ≠ autoridade (ADR-010 D4.1)**: a RLS de *visibilidade* de
  `invitations` usa `is_platform_admin()` (inclui `operator` — despacho cross-tenant,
  ADR-009). As 4 RPCs de **mutação** (`assign_platform_role`, `create_driver`,
  `cancel_invitation`, `add_org_member` path platform) usam `is_super_or_admin()`
  (`super_admin`/`admin`, **exclui** `operator`) — o operator **não** convida/atribui
  (ADR-010 D7). Reusar `is_platform_admin()` em mutação seria escalonamento de
  privilégio (um operator atribuiria papéis a terceiros). **Lição**: V (visibilidade)
  e C/X (autoridade de agir) são eixos distintos; um helper de RLS não deve ser
  reusado como helper de authz de mutação sem confirmar a quem ele inclui.
- **JWT DB-lookup, sem custom claims**: as policies de RLS e a authz dos RPCs resolvem
  o caller via `auth.uid()` + helpers DB-lookup (`is_platform_admin`, `my_org_ids`,
  `my_driver_id`, `my_email`, `is_super_or_admin`). Nada em `auth.hook.custom_access_token`.
  O token nunca mente sobre papéis (lê sempre o estado atual do banco); custom claims
  exigiria reemitir tokens a cada mudança de papel.

### Matriz de autoridade de gestão (Sessão 06, ADR-011 D4)

Estende a matriz RBAC do ADR-009 para a **criação/mutation** de entidades e da corrida.
Todas via RPC `SECURITY DEFINER` (Modelo B) — `authenticated` **sem DML** nessas
tabelas; a única mutação user-facing é a RPC, que checa `auth.uid()` internamente.
`anon`: nada. Visibilidade (SELECT) já coberta pela RLS de 0017.

| RPC | Autorizado (user path) | System path |
|---|---|---|
| `create_organization` | `is_super_or_admin()` (provisionamento de tenant) | permitido (backend) |
| `create_business` | `is_super_or_admin()` **ou** `business_owner` da própria org | permitido |
| `create_business_location` | `business_owner` da org do business **ou** `is_super_or_admin()` | permitido |
| `create_vehicle` | **driver self** (`drivers.user_id = auth.uid()` de `p_driver_id`) **ou** `is_super_or_admin()` | permitido |
| `set_current_vehicle` | driver dono do veículo **ou** `is_super_or_admin()` | permitido |
| `update_driver_status` | `is_super_or_admin()` apenas | **negado** |
| `create_delivery_request` | membro da org (`organization_memberships`) **ou** `is_platform_admin()` (admin/operator) | **permitido** (api/integration/whatsapp) |
| `create_quote` | **negado** (system-only — `auth.uid() IS NOT NULL` → `not_authorized`; `authenticated` sem EXECUTE) | **permitido** (backend cota `draft→quoted`; insumos de rota da plataforma) |
| `confirm_quote` | membro da org **ou** `is_platform_admin()` (admin/operator) | **permitido** (backend confirma `quoted→searching_driver`; valida quote pendente não expirada) |
| `open_dispatch_round` | **negado** (system-only — `auth.uid() IS NOT NULL` → `not_authorized`; `authenticated` sem EXECUTE) | **permitido** (backend abre rodada de dispatch; insumos de raio/oferta do orquestrador) |
| `select_winner_and_claim` | **negado** (system-only — `auth.uid() IS NOT NULL` → `not_authorized`; `authenticated` sem EXECUTE) | **permitido** (backend fecha rodada, pontua, escolhe vencedor, chama `claim_delivery` atômico; pesos de scoring do orquestrador) |

Notas:
- **`create_organization` = super/admin apenas**: criar tenant é ato de plataforma. O
  primeiro `business_owner` entra via convite (0019) depois da org existir.
- **`create_vehicle` = driver self ou admin**: veículos são **driver-owned**
  (`vehicles.driver_id` NOT NULL; drivers platform-scoped). O entregador registra a
  própria moto (PPA na Sessão 17); admin pode provisionar. `create_driver` (0019) é
  admin-only (cria identidade); veículo é posse do driver.
- **`update_driver_status` = super/admin, sem system**: ativa/suspende/bloqueia é
  mutação de **identidade** — alinhado a 0019 (mutação de identidade exige admin
  autenticado, sem system). Fecha o lado driver do risco offboarding (parcialmente:
  `account_status` cobre ativo/suspenso/bloqueado; `remove_platform_role`/
  `remove_org_member` ainda deferidos).
- **`create_delivery_request` aceita system path**: origens `api`/`integration`/
  `whatsapp` (Sessões 13/15–16) criam corrida via backend system-scoped. Dashboard
  (business/admin/operator) usa user path. `operator` (em `is_platform_admin()`) pode
  criar — despacho operacional pode abrir corrida manualmente.
- **`external_reference` = dedup de criação** (não retry): `on conflict
  (organization_id, external_reference) do nothing` → `already_exists` idempotente.
  Distinto de `idempotency_key` (ver **R17** abaixo). Retries de operação ficam com
  `integration_events.idempotency_key` (Sessão 13).
- **Ator capturado por `auth.uid()`** (D6): system → `'system'`; platform admin →
  `'admin'`; membro de org → `'business'`. O `actor_type` nunca vem de parâmetro
  (alinha com `transition_delivery`).

### Matriz de autoridade de dispatch (Sessão 08, ADR-013)

Estende a matriz para o **motor de despacho**. `confirm_quote` é user-facing (membro da
org/operator/admin confirmam a cotação); `open_dispatch_round` é system-only (o
orquestrador/backend abre rodadas — insumos de raio/oferta não vêm do business). Ambas via
RPC `SECURITY DEFINER` (Modelo B); `authenticated` **sem DML** em `dispatch_rounds`/
`delivery_offers` — só EXECUTE em `confirm_quote` + SELECT sob RLS (0017); `anon`: nada.

- **`confirm_quote` aceita user path**: business_owner/business_user (membro da org),
  operator/admin (`is_platform_admin()`) e system (backend). **Transition-first**
  (`quoted→searching_driver` via `transition_delivery`) **antes** de marcar a quote
  `confirmed` — se a transição falhar (race → `wrong_state`), retorna sem marcar (sem
  quote confirmed órfã). Idempotência por estado: re-confirmar → `wrong_state`.
- **`open_dispatch_round` system-only, segundo após `create_quote`**: `authenticated`
  **nem EXECUTE** recebe (defesa em profundidade). **Trust boundary de dispatch:** raio,
  max_candidates, `driver_offer_cents`, janela, `max_location_age_seconds` são insumos do
  orquestrador (backend), não do business — um business passando esses params forjaria a
  busca/oferta. O backend lê config própria (tabela `dispatch_config` adiada). Raio
  progressivo = orquestrador chama N vezes com raios crescentes (D5); `round_number`
  monotônico; guard `round_already_open` (fechar rodada é Sessão 09). Cria a rodada
  **mesmo com 0 candidatos** (audit snapshot). Eligibility MVP (D3): `active`+`available`
  +veículo compatível+sem assignment ativa+localização fresca+`ST_DWithin` no raio
  (proximidade operacional, não cobrança). **Não muta `current_availability_status`**
  (`offered` reservado); guard contra dupla offer na rodada = UK `(round_id, driver_id)`.
- **Sem novos grants de DML a `authenticated`; sem tabela nova** (D8): `dispatch_rounds`/
  `delivery_offers` já têm RLS SELECT (0017) + `service_role` DML (0015). Único grant
  system-only novo: `execute on open_dispatch_round to service_role`.

### Matriz de autoridade de bid (Sessão 09, ADR-014)

Estende a matriz para o **motor de lances / seleção do vencedor**. `select_winner_and_claim`
é system-only (terceiro após `create_quote`/`open_dispatch_round`) — o orquestrador/backend
fecha a rodada, pontua e atribui; os pesos de scoring não vêm do business. Via RPC
`SECURITY DEFINER` (Modelo B); `authenticated` **sem EXECUTE** (defesa em profundidade);
`anon`: nada.

- **`select_winner_and_claim` system-only**: `authenticated` **nem EXECUTE** recebe.
  **Trust boundary de scoring:** `p_weight_price`/`p_weight_distance` são insumos do
  orquestrador (backend), não do business — um business passando os pesos forjaria o
  vencedor (peso preço alto favorece lance alto; peso distância alta favorece o longe).
  O backend lê config própria (`scoring_config` table adiada). Re-valida eligibility do
  driver no close (active+available+veículo compatível+sem assignment ativa+localização
  fresca+`ST_DWithin` no raio da própria rodada+offer não expirada); o driver que ACEITOU
  mas foi atribuído a outra corrida (race) é excluído — sua offer vira `lost` (R16) ou
  `expired` (no_candidates). Sem vencedor → fecha rodada + `no_candidates` (orquestrador
  abre a próxima de raio maior). Com vencedor → `winner_selected` (scores no `metadata`)
  + `claim_delivery` atômico (atribui, fecha rodada, R16 perde demais, `driver_assigned`).
  Idempotência por estado: rodada já `closed` → `round_not_open`.
- **Sem `winner_*` em `dispatch_rounds`**: o vencedor vive em `delivery_assignments`
  (active) + `delivery_offers.status='won'` + `delivery_events`. **Nenhuma
  tabela/coluna nova.**
- **Sem novos grants de DML a `authenticated`; sem tabela nova** (D8): único grant novo =
  `execute on select_winner_and_claim to service_role`. `dispatch_rounds`/`delivery_offers`/
  `bids` já têm RLS SELECT (0017) + `service_role` DML (0015); `claim_delivery`/
  `transition_delivery` já concedidos a `service_role` (0016).

### Matriz de autoridade do ciclo + POD gate (Sessão 11, ADR-016)

Estende a matriz para o **ciclo pós-`assigned`** e a **proof of delivery**. A máquina de
estados `transition_delivery` é refinada (assinatura inalterada) com a matriz
**(ator × transição)** (D1): o ator é resolvido de `auth.uid()` numa classe de papel
(`system`/`admin`/`driver`/`business`); a matriz estrutural M (from→to) é checada primeiro
(`invalid_transition`), depois a matriz de papel R (`not_authorized`). Via RPC
`SECURITY DEFINER` (Modelo B); `authenticated` **sem DML** em `proof_of_delivery` — só
EXECUTE em `transition_delivery`/`submit_proof_of_delivery` + SELECT sob RLS (0017);
`anon`: nada.

- **`transition_delivery` — matriz ator × transição (D1)**: **admin** perde as system-only
  `{draft→quoted, searching_driver→assigned, searching_driver→expired, in_transit→delivered}`
  (usa a RPC dedicada ou é automatizado); pode avançar micro-estados do driver (override
  operacional), cancelar, falhar, reatribuir. **driver** só avanço forward-only
  `{assigned→driver_to_pickup, driver_to_pickup→at_pickup, at_pickup→picked_up,
  picked_up→in_transit}`; **não** pode `delivered`/reatribuir/cancelar/falhar. **business**
  só `{draft→cancelled, quoted→cancelled, quoted→searching_driver, searching_driver→
  cancelled}`; não cancela pós-atribuição, não avança driver. **`draft→cancelled`**
  adicionado a M (business pode cancelar draft). Matriz completa em
  `docs/DELIVERY_LIFECYCLE.md`.
- **Limite de reatribuição (D2)**: em `assigned`/`driver_to_pickup`/`in_transit`/`at_pickup →
  searching_driver`, lê `p_metadata->>'max_reassignments'`; se `reassignment_count >= max`
  → `reassignment_limit_reached` **sem mutar** (orquestrador emite `→failed`). Sem `max` =
  ilimitado (back-compat). Sem tabela de config no MVP — param do caller.
- **`cancelled_reason`/`failed_reason` do metadata (D3)**: ao transitar para `cancelled`/
  `failed`, seta a coluna de `p_metadata->>'reason'` (colunas existiam em 0007 mas nunca
  eram escritas — correção).
- **POD two-phase (D4) — submeter ≠ entregar** (análogo a ACEITAR ≠ GANHAR, ADR-006): por
  causa da sutileza de `auth.uid()` em cadeia DEFINER (lê o JWT GUC, **não muda** com
  SECURITY DEFINER), um RPC driver-scoped não pode disparar uma transição system-only
  internamente. Logo:
  - **`submit_proof_of_delivery`** (driver-scoped: driver com assignment ativa, ou system):
    valida completude (delivery: `storage_path`/`otp_code` + `receiver_name`; pickup: ao
    menos um de `storage_path`/`otp_code`/`notes`) + estado; insere em `proof_of_delivery`
    (unique `(delivery_request_id, pod_type)` → `pod_already_submitted`); emite
    `pod_submitted`; **não transita**. Grants: `service_role` + `authenticated` (user-facing).
  - **`confirm_delivery`** (**system-only**, quarto após `create_quote`/`open_dispatch_round`/
    `select_winner_and_claim`): `authenticated` **nem EXECUTE** recebe (defesa em
    profundidade). Valida POD `pod_type='delivery'` existe (senão `pod_required`) e chama
    `transition_delivery('delivered')` que **re-valida** o POD gate (defense in depth).
    Grants: `service_role` somente.
- **POD gate (D5)**: dentro de `transition_delivery`, `in_transit → delivered` exige POD
  `pod_type='delivery'` — impede **qualquer** path (inclusive system direto sem POD) de
  entregar sem prova. `confirm_delivery` pré-valida (D4) e o gate re-valida — defense in
  depth. "O frontend não marca `delivered`; o backend valida o POD e dispara a transição"
  (regra mestra) — garantido no banco.
- **Sem tabela nova; sem novos grants de DML a `authenticated`** (D8): INSERT em
  `proof_of_delivery` só via DEFINER (RLS INSERT/UPDATE permanece default-deny — sem policy
  nova). Único grant novo: `execute on confirm_delivery to service_role`. **Split 0025/0026**
  (D9): enum `pod_submitted` + unique em 0025 (sem funções), RPCs em 0026 — evita o gotcha
  `ALTER TYPE ... ADD VALUE` in-tx.

### POD completo — OTP do recebedor, gate de geo, gate de pickup, Storage (Sessão 12, ADR-017)

Estende o POD two-phase da Sessão 11 com a **verificação do recebedor (OTP)**, **gate de
geolocalização** e **gate de pickup POD**. **Uma tabela nova** (`delivery_otps`);
**nenhuma coluna nova** em `proof_of_delivery` (D7 — os gates enforce na transição, uma
coluna `verified` seria redundante). Via RPC `SECURITY DEFINER` (Modelo B);
`authenticated` só EXECUTE em `submit_proof_of_delivery`/`transition_delivery` + SELECT
sob RLS em `delivery_otps`; `anon`: nada.

- **Ciclo de vida do OTP — hash salt+sha256, TTL, lockout (D1)**: o código de 6 dígitos é
  gerado com crypto (`gen_random_bytes`) e armazenado **só** como `sha256(code || salt)` em
  `delivery_otps` (`salt = gen_random_bytes(8)` por linha) — o plaintext **nunca** persiste.
  `unique (delivery_request_id)` (delivery-only; 1 OTP ativo por corrida). TTL default
  900s (`expires_at`); lockout após `max_attempts` (default 5) tentativas erradas
  (`attempts++`, `otp_max_attempts`). Match → `consumed_at=now()` (1 uso). Upsert
  regenera (reseta `attempts`/`consumed_at`). Validação em `submit_proof_of_delivery` com
  `select ... for update` (lock de linha contra race de submit concorrente) **antes** do
  insert do POD; match consume na mesma tx do insert (atomicidade — OTP e POD ficam
  consumidos/inseridos juntos, ou nada). Razões: `otp_not_generated`/`otp_expired`/
  `otp_max_attempts`/`otp_already_used`/`otp_invalid`.
- **Geração system-only (D9)**: `generate_delivery_otp` é o **5º system-only**. O código
  devolvido **só** ao caller system (`auth.uid() IS NULL`) — o backend o encaminha via
  WhatsApp ao `delivery_contact_phone`. Se o driver pudesse gerar o OTP, veria o código e
  poderia forjar a "verificação" do recebedor. `authenticated` **nem EXECUTE** recebe; o
  driver só submete (`submit_proof_of_delivery`), que valida o código contra o hash — nunca
  recebe o plaintext.
- **Verificação do recebedor = OTP match; foto = evidência (D4)**: delivery POD com
  `otp_code` DEVE bater com um OTP gerado. Foto-only (`otp_code` null) é aceito (either-or,
  back-compat Sessão 11) mas **não verifica** o recebedor — é evidência visual. A
  profundidade Sessão 12: se `otp_code` vier, é validado de verdade (não texto livre como na
  Sessão 11).
- **Gate de geolocalização (configurável, duro) (D2)**: dentro de `transition_delivery` em
  `in_transit→delivered`, após o gate de existência. `v_tol :=
  nullif(metadata->>'geo_tolerance_m','')::int`, default 200m. Se o POD delivery tem
  `location_point`, `v_dist := st_distance(pod_loc, delivery_point)`; se `> v_tol` →
  `pod_geolocation_out_of_range` **sem mutar**. Se o POD **não tem location** → **skip**
  (GPS de PWA é impreciso; não se valida o que não foi capturado). Gate duro **quando** há
  localização; ausência aceita no MVP (endurecer para exigir location fica para sessão
  posterior). Tolerância configurável via `confirm_delivery(p_geo_tolerance_m)` →
  `metadata.geo_tolerance_m`.
- **Gate de pickup POD (D3)**: dentro de `transition_delivery`, `at_pickup→picked_up`
  exige POD `pod_type='pickup'` (senão `pickup_pod_required` sem mutar). Espelha o gate de
  delivery — o driver submete o pickup POD antes de marcar `picked_up`.
- **Storage `pod-photos` (privado, D5)**: bucket criado via migration (`public=false`,
  `file_size_limit=50MiB`, `allowed_mime_types=['image/png','image/jpeg']`, guard `on
  conflict do nothing`). RLS policy `pod_photos_insert` FOR INSERT TO authenticated WITH
  CHECK (`bucket_id='pod-photos' and is_assigned_driver_of((storage.foldername(name))[1]
  ::uuid)`) — helper `is_assigned_driver_of(uuid)` SECURITY DEFINER stable (bypassa RLS
  dentro da policy de `storage.objects`, evita recursão). Path convencionado
  `pod-photos/{delivery_request_id}/{pod_type}/{uuid}.ext`. **Sem** SELECT/UPDATE/DELETE p/
  `authenticated` — reads só via **URL assinada** emitida pelo backend/service_role (o
  driver envia o path no POD; quem lê a foto é o sistema, não o client anônimo). Default-
  deny otherwise. **Validação comportamental de Storage RLS deferida** (Storage é API
  separada, não exercitável via curl `/database/query`) — só validação **estrutural** (bucket
  + policy existem) feita no replay; a validação comportamental fica para quando houver app
  Next.js (Sessões 17-19) e Storage API exercitável.
- **Sem novos grants de DML a `authenticated`** (D8): único grant novo em `public` é SELECT
  em `delivery_otps` (under RLS). INSERT em `proof_of_delivery`/`delivery_otps` só via
  DEFINER. `generate_delivery_otp`/`confirm_delivery` system-only (execute só
  `service_role`); `submit_proof_of_delivery`/`transition_delivery` grants inalterados.
  **Split 0027/0028** (D9): enum `otp_generated` + `delivery_otps` + bucket em 0027 (sem
  funções), RPCs em 0028 — evita o gotcha `ALTER TYPE ... ADD VALUE` in-tx.
- **Camada externa (n8n/WhatsApp): validação live deferida** (D6): `generate_delivery_otp`
  é DB (construído/validado). O Route Handler de confirm, o workflow n8n #13 e o envio do
  OTP via WhatsApp são **especificados** (docs) — não live-validados (não há n8n/WhatsApp
  provisionados). Não simulado (regra mestra). Live-validação: Sessões 14 (n8n) + 15-16
  (WhatsApp/DataCrazy).

### Concorrência real — GATE de produção (Sessão 10, ADR-015)

- **Invariante ADR-007 (≤1 `delivery_assignment` ativa por `delivery_request`) validada
  em concorrência REAL** — backends concorrentes em conexões separadas, não
  single-transaction. 5 runs × 3 races (A: 2 `claim_delivery` paralelos; B: 2
  `select_winner_and_claim` paralelos; C: SWAC vs claim direto) — todas sustentaram
  `n_assign=1, n_won=1, del_status='assigned', round_status='closed'`. Mecanismo: curls
  paralelos ao Management API (`dblink_connect_u` negado/não-superuser; senha nunca na
  linha de comando — vazamento bloqueado). Harness em `supabase/tests/concurrency_harness.sh`.
- **Achado de lock-ordering (deadlock latente, não-hazard vivo)**: `select_winner_and_claim`
  adquire round→delivery; `claim_delivery` adquire delivery→(UPDATE round late). Claim
  **direto** concorrente com SWAC cross-tx forma ciclo → 40P01 (reproduzido no Test C;
  invariante sobreviveu — Postgres aborta um tx, o outro vence). **Não é hazard vivo**:
  `claim_delivery` só roda dentro de SWAC (mesma transação, re-lock reentrante). Dívida
  técnica observada: se um futuro camino chamar claim direto concorrente com SWAC
  (reatribuição de emergência, legado), endurecer o lock order. Não muda o invariante.

## Idempotência

- `idempotency_key` em endpoints mutantes; `external_event_id` por evento.
- `integration_events(idempotency_key, source, external_event_id)` UNIQUE por origem.
- `webhook_events(source, external_id)` UNIQUE → dedup de webhooks.
- Aplica-se a: criação de pedido, confirmação de cotação, respostas a ofertas,
  bids, claim, transições, webhooks, notificações, pagamentos futuros, e
  **aceitar convite** (`accept_invitation` idempotente; ver ADR-010 D3).
- **Retries são parte normal da arquitetura.**

### R17 — `external_reference` ≠ `idempotency_key` (conceitos distintos)

Estes dois campos **não são a mesma coisa** e vivem em tabelas diferentes. Misturá-los
quebra a semântica de idempotência:

- **`idempotency_key`** (em `integration_events`, `bids`, `notifications`): chave de
  idempotência **da operação**. Garante que um **retry** da mesma chamada (mesma
  chave) não duplique efeito. Domínio do **backend/sistema** que executa a operação.
  `UNIQUE` global (ou por `source`) → segundo insert com a mesma chave vira replay e
  retorna o resultado já existente (não erro, não duplicação).
- **`external_reference`** (em `delivery_requests`): identificador **do registro no
  sistema de origem externa** (ex.: o pedido nº 1234 no ERP da empresa). É o vínculo
  do mundo externo com a corrida ViO10 — **não** é chave de retry. `UNIQUE` por
  `organization_id` → uma mesma organização não cria duas corridas para o mesmo
  `external_reference`. Pode ser `NULL` (corridas criadas direto no ViO10).
- **`external_event_id`** (em `integration_events`, `webhook_events.external_id`):
  id do **evento** recebido do emissor externo — dedup de **webhooks/eventos
  inbound** (o emissor reenvia o mesmo evento; o ViO10 não reprocessa).

Regra prática:

| Quero evitar... | Uso |
|---|---|
| Retry duplicando efeito de uma operação | `idempotency_key` |
| Duas corridas para o mesmo pedido externo | `delivery_requests.external_reference` (`UNIQUE` por org) |
| Reprocessar o mesmo webhook/evento inbound | `external_event_id` / `webhook_events.external_id` |

Quando `external_reference` é `NULL`, a idempotência da criação da corrida fica por
conta do `idempotency_key` em `integration_events` (camada de integração), não da
tabela de domínio.

## Links de ação (ofertas)

- Assinados (HMAC/JWT curto) e **expiráveis**.
- Escopo limitado à offer/driver específicos.
- Replay/forja → rejeitado.
- IDOR protegido: nenhum recurso acessível por ID adivinhável sem autorização.

## Concorrência / atomicidade

- Atribuição de corrida: constraint parcial `UNIQUE (delivery_request_id) WHERE
  status='active'` + RPC `claim_delivery()` com `FOR UPDATE`.
- Transições de estado: RPC `transition_delivery()` transacional.
- Cancelar vs atribuir simultâneos → resolvido pelo lock na `delivery_requests`.

## Storage / uploads (prova de entrega)

- **Supabase Storage** com **policies privadas**.
- Uploads autorizados e validados (tipo/tamanho). Nada de dados desnecessários.
- URLs assinadas/efêmeras para acesso.
- **Bucket `pod-photos`** (Sessão 12, ADR-017 D5): privado (`public=false`),
  `file_size_limit=50MiB`, `allowed_mime_types=['image/png','image/jpeg']`. RLS INSERT p/
  `authenticated` (`pod_photos_insert`) via helper `is_assigned_driver_of` (assignment
  ativa). Path `pod-photos/{delivery_request_id}/{pod_type}/{uuid}.ext`. Reads só via URL
  assinada (backend/service_role); default-deny otherwise. **Validação comportamental de
  Storage RLS deferida** (Storage é API separada, não exercitável via curl) — validação
  estrutural feita no replay; live fica para Sessões 17-19 (app Next.js).

## Secrets / env

- Nada de secrets no frontend nem no git.
- Variáveis de ambiente no backend; nunca expostas ao cliente.
- Webhooks recebidos validam assinatura do emissor quando aplicável.

## Observabilidade vs PII

- Logs carregam `correlation_id`, contexto operacional, resultado, erro.
- **PII mínima** em logs. Localização do entregador com TTL/consentimento; coleta
  só em corrida ativa ou quando autorizado.
- Documentar retention quando aplicável.

## Rate limiting / abuso

- Endpoints externos (webhooks, APIs públicas) com rate limiting.
- Proteção contra abuso de lances (limite por rodada por entregador, configurável).
- Proteção contra replay.

## Notas de segurança externas já registradas

- **Next.js 16.3.3** (25/ago/2026): corrige RCE em otimização AVIF
  (GHSA-2xp9-vwfh-vxw4) e RCE em Windows (GHSA-p293-qw3h-jr36 — não nos atinge,
  deploy Linux/Vercel). AVIF desabilitado na patch.
  Fonte: [August 2026 Security Release](https://nextjs.org/blog/august-2026-security-release).

## Tópicos para a Sessão 22 (auditoria)

Autenticação, autorização, RLS, APIs, server actions, webhooks, uploads, storage,
links de aceitação, secrets, env vars, DataCrazy, n8n, banco, logs, PII, endpoints
administrativos, rate limiting, abuso, replay, IDOR, injection, concorrência.
Classificação: CRÍTICO / ALTO / MÉDIO / BAIXO.