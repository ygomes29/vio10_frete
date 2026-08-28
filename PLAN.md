# PLAN.md — Roadmap do ViO10

## Status atual

- **Sessão 01**: diagnóstico — **aprovado com ajustes**.
- **Sessão 02**: documentação-mãe + ADRs — **concluída**.
- **Sessão 03**: fundação do banco — **concluída (Gate B implementado)**.
- **Sessão 03.5 (atual)**: validação real da fundação — **concluída — PASS**.
  - 14 migrations em `supabase/migrations/` (extensões, enums, helpers, identidade/tenancy,
    drivers, service_areas, delivery core, pricing, dispatch/bids, assignments/events,
    integrações/notificações/POD, RLS default deny, RPCs, grants hardening).
  - RPCs atômicos: `claim_delivery`, `respond_to_offer`, `transition_delivery`,
    `set_driver_availability`.
  - PostGIS habilitado (geography + GiST, schema `extensions`); Google Maps atrás de
    abstração (Sessão 20).
  - Invariante crítica protegida: partial unique index em `delivery_assignments` +
    `claim_delivery` com `FOR UPDATE`.
  - RLS habilitado em todas as tabelas, **default deny**; **grants also default deny**
    (0014 revoga de `anon`/`authenticated`/`service_role`; policies/grants finais na
    Sessão 04).
  - **Testes executados (real, server-side, sem Docker)**: pgTAP **12/12 invariantes
    PASS**; RPCs **48/48 PASS**; concorrência `claim_delivery` (exatamente 1 vencedor);
    `delivery_events` imutável; RLS default-deny; grants audit (0 privilégios para
    roles não-owner). Cadeia 0001→0014 reproduzida do zero.
  - Correções: PostGIS search_path; 0014 endurecido (auto-grants Supabase); R16
    cross-round; R17 (`external_reference` ≠ `idempotency_key`); `service_role`
    user-scoped vs system-scoped.
  - Financeiro (payments/payouts/ledger) **adiado** à Sessão 21 (nenhuma FK atual depende).
- **Sessão 04 (atual)**: Auth/Grants/RLS/RBAC (Modelo B) — **concluída — PASS**.
  - **17 migrations** em `supabase/migrations/` (0001-0015 da 03/03.5 + **0016** RPCs
    `SECURITY DEFINER` + **0017** RLS policies).
  - **ADR-009**: matriz RBAC (6 papéis × recursos × ações) — spec antes do código.
  - **Modelo B** (decisão de usuário): RPCs user-facing `SECURITY DEFINER` +
    checagem `auth.uid()` interna; reverte INVOKER da Sessão 03; fecha bypass da
    máquina de estados via PostgREST.
  - Grants least-privilege (0015): `service_role` DML + 4 RPCs; `authenticated`
    SELECT(20) sob RLS + 3 RPCs user-facing + INSERT/UPDATE só em `driver_locations`;
    `anon` nada.
  - RLS policies (0017) + 5 helpers DEFINER: visibilidade por org/driver/admin;
    default-deny; bypass UPDATE em `delivery_requests` bloqueado.
  - **Validado real** (dev `rtoyfiqngyicqtuzwfhz`): authz **21/21 PASS**; system-path
    claim **4/4**; R16 cross-round **PASS**; concorrência **exatamente 1 vencedor**;
    inventário final consistente (26 RLS, 25 policies, 4 DEFINER, 5 helpers, anon=0).
  - Bypass da máquina de estados via PostgREST: **FECHADO**.
- **Sessão 05 (atual)**: Auth de usuários (Supabase Auth) + reset/replay from-scratch —
  **concluída — PASS**.
  - **19 migrations** em `supabase/migrations/` (0001-0017 + **0018** trigger
    `handle_new_user` + **0019** `invitations` + 6 RPCs de identidade/convite).
  - **ADR-010**: ciclo de vida de identidade e auth (MVP) — email+senha, trigger de
    perfil, convites via `invitations`+`accept_invitation` (anon não acessa; prova
    propriedade do email via login), RPCs admin DEFINER, JWT DB-lookup sem custom
    claims, cookie-based, matriz de quem convida quem.
  - **0018 `handle_new_user`** (`SECURITY DEFINER` on `auth.users` AFTER INSERT →
    `profiles`): garante FK de papéis/memberships/drivers → `profiles(id)`.
  - **0019**: `invitations` (RLS) + 6 RPCs DEFINER (`create_invitation`,
    `accept_invitation`, `cancel_invitation`, `assign_platform_role`,
    `add_org_member`, `create_driver`) + helpers `my_email()`, `is_super_or_admin()`.
  - **Bug de escalonamento de privilégio corrigido na validação**: mutação usava
    `is_platform_admin()` (inclui `operator`) → `operator` atribuía papéis. Corrigido
    para `is_super_or_admin()` (super/admin). Visibilidade mantém `is_platform_admin()`
    (operator vê — leitura). ADR-010 D4.1.
  - **`supabase/config.toml`**: senha forte (12, lower/upper/digits/symbols),
    `enable_anonymous_sign_ins=false`, sem phone/SMS signup (MVP).
  - **Hardening final — reset/replay from-scratch**: `drop schema public cascade` +
    `delete from auth.users` (via SQL + Management API; não há reset a nível de
    projeto, só branch) + replay **0001→0019 em ordem** → 19/19 limpo. Inventário: 26
    tabelas (incl. `invitations`), RLS 26/26, trigger presente, `anon`=0.
  - **Validado real** (dev `rtoyfiqngyicqtuzwfhz`): invariants **13/13**, rpcs **48/48**,
    authz **21/21**, auth_lifecycle **34/34** — todas PASS (não simulado). Risco
    "reset/replay não executado" (BAIXO, Sessão 04) **FECHADO**.
  - Revogação de papel / offboarding e limpeza assíncrona de convites expirados
    **adiados** (Sessão 06+; `accept_invitation` já rejeita expirados).
- **Sessão 06**: Criação da corrida + gestão de empresas/veículos/entregadores —
  **concluída — PASS**.
  - **21 migrations** em `supabase/migrations/` (0001-0019 + **0020** management RPCs +
    **0021** `create_delivery_request`). **Nenhuma tabela nova**; único schema change:
    `idx_vehicles_plate_uk` (unique em `vehicles.plate`).
  - **ADR-011**: criação da corrida + gestão de entidades. Criação = `draft` + itens +
    evento `delivery_created` (sem preço; pricing é Sessão 07). Snapshots auto-contidos;
    pontos PostGIS montados server-side. `external_reference` = dedup (não retry).
    Matriz de autoridade de gestão D4 (estende ADR-009). Mutação só via RPC DEFINER.
    Capture de ator por `auth.uid()`.
  - **0020** — 6 RPCs DEFINER: `create_organization`, `create_business`,
    `create_business_location`, `create_vehicle` (driver self ou admin; driver-owned),
    `set_current_vehicle`, `update_driver_status` (super/admin, sem system).
  - **0021** — `create_delivery_request` DEFINER: `draft` + `delivery_items` +
    `delivery_events(delivery_created)` atômico. Authz system/admin/membro de org.
  - **Offboarding parcial**: `update_driver_status` (active/suspended/blocked) fecha o
    lado driver do risco em aberto; `remove_platform_role`/`remove_org_member` ainda
    deferidos.
  - **Hardening — reset/replay from-scratch**: `drop schema public cascade` +
    `delete from auth.users` (via SQL + Management API) + replay **0001→0021 em ordem**
    → 21/21 limpo. Inventário: 26 tabelas, RLS 26/26, 7 novos RPCs DEFINER,
    `vehicles.plate` unique, `anon`=0 em `public`.
  - **Validado real** (dev `rtoyfiqngyicqtuzwfhz`): invariants **13/13**, rpcs **48/48**,
    authz **21/21**, auth_lifecycle **34/34**, creation **37/37** — todas PASS (não
    simulado). Bug T4 corrigido na validação (JWT residual em `create_vehicle`).
  - **Veredito**: GO para Sessão 07.
- **Sessão 07 (atual)**: Pricing engine determinístico (cotação, `draft → quoted`) —
  **concluída — PASS**.
  - **22 migrations** em `supabase/migrations/` (0001-0021 + **0022** `create_quote`).
  **Nenhuma tabela nova**; altera `pricing_rules` (+`min_multiplier`/`max_multiplier`) e
  `delivery_quotes` (+`min/max_customer_price_cents`/`min/max_driver_offer_cents`).
  - **ADR-012**: pricing determinístico. D1 `create_quote` **system-only** (primeiro
    RPC system-only; `auth.uid() not null`→`not_authorized`; trust boundary de insumos
    de rota do backend); D2 álgebra (`customer=subtotal+fee`, `driver=subtotal−fee`,
    `distance_component` ceil inteiro, `vehicle`/`dynamic`=0 no MVP); D3 faixa min/max
    via multipliers; D4 regra org→global→`no_pricing_rule`; D5 atomicidade
    transition-first; D6 ator via `auth.uid`; D7 TTL 900s `pending`; D8 idempotência por
    estado.
  - **0022** — `create_quote` DEFINER (system-only; `revoke public` + `execute` só a
    `service_role`, `authenticated` sem EXECUTE; `anon` nada).
  - **Hardening — reset/replay from-scratch**: `drop schema public cascade` +
    `delete from auth.users` + replay **0001→0022 em ordem** → 22/22 limpo. Inventário:
    26 tabelas, RLS 26/26, `create_quote` DEFINER, colunas novas, `authenticated` sem
    EXECUTE em `create_quote`, `anon`=0 em `public`.
  - **Validado real** (dev `rtoyfiqngyicqtuzwfhz`): invariants **13/13**, rpcs **48/48**,
    authz **21/21**, auth_lifecycle **34/34**, creation **37/37**, pricing **62/62** —
    todas PASS (não simulado). Bug de ambiguidade PL/pgSQL corrigido (`select ok, reason`
    → alias `t.ok, t.reason`).
  - **Veredito**: GO para Sessão 08.
- **Sessão 08 (atual)**: Dispatch engine (busca de candidatos + raio progressivo,
  `quoted → searching_driver`) — **concluída — PASS**.
  - **23 migrations** em `supabase/migrations/` (0001-0022 + **0023** `confirm_quote` +
    `open_dispatch_round`). **Nenhuma tabela/coluna nova** — tudo já existe em
    0005/0009/0010.
  - **ADR-013**: dispatch engine. D1 `confirm_quote` user-scoped (membro da org/operator/
    admin/system confirma cotação pendente; transition-first `quoted→searching_driver`,
    marca quote `confirmed`+`confirmed_at`, sem órfã); D2 `open_dispatch_round` system-only
    (segundo system-only; trust boundary de insumos de dispatch); D3 eligibility MVP
    (active+available+veículo compatível+sem assignment ativa+localização fresca+`ST_DWithin`
    no raio; `service_areas` por entregador adiado); D4 criação atômica de rodada+offers;
    D5 raio progressivo orquestrado (não no RPC); D6 atomicidade/guards; D7 ator via
    `auth.uid`; D8 sem novos grants de DML a `authenticated`, sem tabela nova.
  - **0023** — 2 RPCs DEFINER: `confirm_quote` (user-scoped; grants service_role+
    authenticated) e `open_dispatch_round` (system-only; grants só service_role,
    authenticated sem EXECUTE — defesa em profundidade). PostGIS `st_dwithin`/`st_distance`
    não-qualificados (schema `extensions`). `offered` reservado (não muta availability).
  - **Hardening — reset/replay from-scratch**: `drop schema public cascade` +
    `delete from auth.users` + replay **0001→0023 em ordem** → 23/23 limpo. Inventário: 26
    tabelas (nenhuma nova), RLS 26/26, `confirm_quote` DEFINER (execute service_role+
    authenticated), `open_dispatch_round` DEFINER system-only (execute só service_role,
    authenticated sem EXECUTE), `anon`=0 em `public`.
  - **Validado real** (dev `rtoyfiqngyicqtuzwfhz`): invariants **13/13**, rpcs **48/48**,
    authz **21/21**, auth_lifecycle **34/34**, creation **37/37**, pricing **62/62**,
    dispatch **65/65** — todas PASS (não simulado). Nenhum bug em runtime (lições da
    Sessão 07 — ambiguidade `as t` e PostGIS em `extensions` — aplicadas proativamente).
  - **Veredito**: GO para Sessão 09.
- **Sessão 09 (atual)**: Bid engine (scoring + seleção + `claim_delivery` atômico,
  `searching_driver → assigned`) — **concluída — PASS**.
  - **24 migrations** em `supabase/migrations/` (0001-0023 + **0024**
    `select_winner_and_claim`). **Nenhuma tabela/coluna nova** — tudo já existe em
    0005/0009/0010/0016.
  - **ADR-014**: bid engine. D1 `select_winner_and_claim` system-only (terceiro
    system-only; trust boundary de pesos de scoring); D2 fluxo (validate → coletar →
    0: fechar manual | ≥1: pontuar → claim); D3 candidatos válidos = responded +
    ainda-eligible (re-valida eligibility no close); D4 scoring min-max + pesos de param +
    tie-break determinístico (`score desc, dist_m asc, responded_at asc, driver_id asc`);
    D5 seleção≠confirmação (`claim_delivery` confirma); D6 auditoria via `delivery_events`
    (scores no metadata, sem coluna de winner); D7 ator via `auth.uid`; D8 sem novos grants
    de DML a `authenticated`, sem tabela/coluna nova.
  - **0024** — `select_winner_and_claim` DEFINER system-only (`search_path = public,
    extensions, pg_catalog` — PostGIS `ST_Distance`/`ST_DWithin`; grants só service_role,
    authenticated sem EXECUTE — defesa em profundidade). Fecha a rodada, pontua candidatos
    válidos (min-max de `bid_amount_cents` + `ST_Distance`, pesos de param), escolhe
    vencedor, chama `claim_delivery` atomicamente. Sem vencedor → fecha + `no_candidates`
    (orquestrador abre a próxima de raio maior). Com vencedor → `winner_selected` (scores
    no metadata) + `claim_delivery` (atribui, fecha rodada, R16, `driver_assigned`).
  - **Hardening — reset/replay from-scratch**: `drop schema public cascade` +
    `delete from auth.users` + replay **0001→0024 em ordem** → 24/24 limpo. Inventário: 26
    tabelas (nenhuma nova), RLS 26/26, `select_winner_and_claim` DEFINER system-only
    (execute só service_role, authenticated sem EXECUTE), `anon`=0 em `public`.
  - **Validado real** (dev `rtoyfiqngyicqtuzwfhz`): invariants **13/13**, rpcs **48/48**,
    authz **21/21**, auth_lifecycle **34/34**, creation **37/37**, pricing **62/62**,
    dispatch **65/65**, bid **61/61** — todas PASS (não simulado). Bugs de teste
    corrigidos (poluição cross-scenario via pickup compartilhado → isolamento por
    longitude; asserção invertida T2). Nenhum bug de RPC em runtime (lições Sessão 07/08
    aplicadas proativamente).
  - **Veredito**: GO para Sessão 10.
- **Sessão 10 (atual)**: Atribuição atômica em concorrência real (GATE de produção,
  ADR-007/ADR-015) — **concluída — PASS**.
  - **ADR-015**: harness de concorrência real. D1 mecanismo = curls paralelos ao
    Management API (`dblink_connect_u` negado/não-superuser; senha nunca na linha de
    comando; verificado empiricamente — N curls paralelos rodam em conexões backend
    separadas concorrentemente); D2 três races (A: 2 `claim_delivery` paralelos; B: 2
    `select_winner_and_claim` paralelos; C: SWAC vs claim direto — observacional); D3
    invariante do GATE (≤1 assignment ativa, exatamente 1 won, assigned, closed —
    determinístico no DB); D4 achado de lock-ordering (deadlock latente 40P01,
    não-hazard vivo — claim só roda dentro de SWAC; reproduzido empiricamente, invariante
    sobreviveu; hardening adiado); D5 sem migration/schema/grant novo; D6 critério PASS
    (≥5 runs reais); D7 ambiente/segurança (dev only).
  - **Harness** commitado: `supabase/tests/concurrency_harness.sh` +
    `concurrency_setup.sql` — reset + replay 0001→0024 + inventário + 8 suítes de
    regressão + 3 races × N runs.
  - **GATE PASS**: invariante ADR-007 sustentado em **5 runs × 3 races = 15 corridas reais
    paralelas** (não simulado). Todas: `n_assign=1, n_won=1, n_lost=1, assigned, closed`.
    Test A: 1 `won` + 1 `not_searching_driver`. Test B: 1 `won` + 1 `round_not_open`.
    Test C: 1 vencedor + 1 perdedor (run 2 reproduziu 40P01 — invariante sobreviveu).
  - **Bug de harness corrigido**: 1ª versão reusava longitudes entre runs → drivers
    perdedores de runs anteriores vazavam para eligibility posterior (`n_lost` crescia);
    invariante núcleo nunca violado. Corrigido com offset 1°/run (~111km >> raio 10km).
  - **Sem migration, sem schema/RPC/grant novo** — Sessão 10 é validação.
  - **Hardening — reset/replay from-scratch**: reset via SQL + replay **0001→0024** →
    24/24 limpo. Inventário: 26 tabelas, RLS 26/26, SWAC system-only, `anon`=0 em public.
  - **Validado real** (dev `rtoyfiqngyicqtuzwfhz`): invariants **13/13**, rpcs **48/48**,
    authz **21/21**, auth_lifecycle **34/34**, creation **37/37**, pricing **62/62**,
    dispatch **65/65**, bid **61/61** — todas PASS (regressão, não simulado).
  - **Risco aberto (BAIXO) — novo**: lock-ordering `claim_delivery`↔SWAC (D4) — dívida
    técnica observada, não-hazard vivo. Offboarding/revogação de papel/membership
    permanece deferido (Sessão 06).
  - **Veredito**: **GATE PASS** → GO para Sessão 11 (ciclo completo: máquina de estados
    + proof of delivery).
- **Sessão 11**: Ciclo completo (máquina de estados pós-`assigned` + POD gate) —
  **concluída — PASS**.
  - **26 migrations** em `supabase/migrations/` (0001-0024 + **0025** schema prep +
    **0026** 3 RPCs). **Nenhuma tabela/coluna nova**; enum `pod_submitted` + unique
    `(delivery_request_id, pod_type)` em `proof_of_delivery`.
  - **ADR-016**: ciclo completo pós-`assigned` + POD gate. D1 matriz de authz por
    (ator × transição) dentro de `transition_delivery` (system/admin/driver/business —
    M estrutural primeiro, depois R de papel; admin perde system-only, driver forward-only,
    business só pré-atribuição; `draft→cancelled` adicionado a M); D2 limite de reatribuição
    via `p_metadata->>'max_reassignments'` (sem teto = ilimitado, back-compat); D3
    `cancelled_reason`/`failed_reason` do metadata (colunas existiam mas nunca escritas);
    D4 POD two-phase `submit_proof_of_delivery` (driver-scoped) + `confirm_delivery`
    (system-only) — "Submeter POD ≠ entregue"; D5 POD gate em `in_transit→delivered`
    (defense in depth); D6 completude do POD no MVP; D7 ator via `auth.uid()` + evento
    `pod_submitted`; D8 sem tabela nova; D9 split 0025/0026 (gotcha enum-add-value in-tx).
  - **0025** — schema prep (sem funções): enum `pod_submitted` + unique
    `(delivery_request_id, pod_type)`.
  - **0026** — 3 RPCs DEFINER: `transition_delivery` **refinada** (assinatura inalterada),
    `submit_proof_of_delivery` (driver-scoped/system; valida + insere + emite `pod_submitted`;
    **não transita**), `confirm_delivery` (**system-only**; valida POD + chama
    `transition_delivery('delivered')` que re-valida o gate). Grants: transition/submit →
    service_role+authenticated; confirm → service_role somente (authenticated sem EXECUTE).
  - **Callers internos preservados**: `create_quote`/`confirm_quote` não quebrados;
    `claim_delivery`/SWAC não chamam `transition_delivery` — GATE Sessão 10 íntegro.
  - **Hardening — reset/replay from-scratch**: `drop schema public cascade` +
    `delete from auth.users` + replay **0001→0026 em ordem** → 26/26 limpo. Inventário: 26
    tabelas (nenhuma nova), RLS 26/26, POD unique, enum `pod_submitted`, `confirm_delivery`
    DEFINER system-only (execute só service_role), `anon`=0 em `public`.
  - **Validado real** (dev `rtoyfiqngyicqtuzwfhz`): invariants **13/13**, rpcs **48/48**,
    authz **21/21**, auth_lifecycle **34/34**, creation **37/37**, pricing **62/62**,
    dispatch **65/65**, bid **61/61**, lifecycle (novo) **65/65** — **9/9 suítes, 406
    asserções, todas PASS (não simulado)**. Bug de teste corrigido (leak residual de JWT —
    lição Sessão 06 reconfirmada: cada bloco autenticado reseta JWT para `'{}'` antes dos
    helpers, seta o ator, reseta antes de system-only). `test_vio10_rpcs` TR8 ajustado
    (POD gate).
  - **Veredito**: GO para Sessão 12 (POD completo: foto/OTP/geolocation/recebedor).
- **Sessão 12 (atual)**: POD completo (OTP do recebedor, gate de geo, gate de pickup POD,
  Storage) — **concluída — PASS (com ressalva)**.
  - **28 migrations** em `supabase/migrations/` (0001-0026 + **0027** schema prep +
    **0028** 4 RPCs). **Uma tabela nova** (`delivery_otps`, delivery-only); **nenhuma
    coluna nova** em `proof_of_delivery` (D7). Enum `otp_generated`.
  - **ADR-017**: POD completo. D1 ciclo de vida do OTP em `delivery_otps` (hash salt+sha256,
    TTL default 900s, lockout default 5, geração **system-only** via
    `generate_delivery_otp`, validação no `submit_proof_of_delivery` com `for update`, match
    consume na mesma tx do insert); D2 gate de geo em `in_transit→delivered`
    (configurável via `metadata.geo_tolerance_m`, default 200m, `st_distance`, skip se POD
    sem location); D3 gate de pickup POD em `at_pickup→picked_up` (`pickup_pod_required`);
    D4 verificação do recebedor = OTP match (foto = evidência, either-or preservado); D5
    bucket `pod-photos` privado + RLS INSERT p/ driver com assignment ativa (helper
    `is_assigned_driver_of`); D6 camada externa (n8n #13 + WhatsApp OTP) **especificada**,
    validação live **deferida** (sem simular PASS); D7 sem coluna `verified`; D8 split
    0027/0028 (gotcha enum-add-value in-tx); D9 ator via `auth.uid()` (5º system-only).
  - **0027** — schema prep (sem funções): enum `otp_generated` + tabela `delivery_otps`
    (unique `delivery_request_id`) + RLS/grants + helper `is_assigned_driver_of` + bucket
    `pod-photos` + policy `pod_photos_insert` em `storage.objects`.
  - **0028** — 4 RPCs DEFINER: `generate_delivery_otp` (**nova, system-only** — 5º; código
    6 dígitos crypto, hash salt+sha256, upsert, emite `otp_generated`), `submit_proof_of_delivery`
    (**refinada**, assinatura inalterada; valida OTP contra `delivery_otps` com `for update`,
    match → `consumed_at=now()` na mesma tx; foto-only pula), `confirm_delivery`
    (**refinada**, assinatura mudou — drop 2-param antes do create; novo `p_geo_tolerance_m`
    → `metadata.geo_tolerance_m`), `transition_delivery` (**refinada**, assinatura
    inalterada; `search_path` agora `public, extensions, pg_catalog`; gate de pickup POD
    + gate de geo). Grants: generate/confirm → service_role somente (system-only);
    submit/transition → service_role+authenticated (inalterado).
  - **Callers internos preservados**: `create_quote`/`confirm_quote`/`confirm_delivery`
    chamam `transition_delivery` com assinatura inalterada — gates condicionais ao
    `p_to_status`. `claim_delivery`/SWAC não chamam `transition_delivery` — GATE Sessão 10
    íntegro.
  - **Hardening — reset/replay from-scratch**: `drop schema public cascade` +
    `delete from auth.users` + replay **0001→0028 em ordem** → 28/28 limpo. Inventário: 27
    tabelas (`delivery_otps` nova), RLS 27/27, `anon`=0, `generate_delivery_otp` system-only
    (5º; execute só service_role), `confirm_delivery` 3-param (2-param dropped), bucket
    `pod-photos` (privado) + policy `pod_photos_insert`.
  - **Validado real** (dev `rtoyfiqngyicqtuzwfhz`): invariants **13/13**, rpcs **48/48**,
    authz **21/21**, auth_lifecycle **34/34**, creation **37/37**, pricing **62/62**,
    dispatch **65/65**, bid **61/61**, lifecycle **67/67** (pickup POD antes de `picked_up`),
    pod_completo (novo) **40/40** — **10/10 suítes, 418 asserções, todas PASS (não
    simulado)**. Bug de teste corrigido (C1: 2º submit reusa OTP consumido →
    `otp_already_used` antes de `pod_already_submitted`; reescrito em 3 passos).
  - **Ressalva (regra mestra — não simular PASS)**: **Storage RLS comportamental** não
    validado live (Storage é API separada, não exercitável via curl; só validação
    estrutural — bucket + policy). **Camada n8n/WhatsApp** não live-validada (workflow #13
    + envio OTP especificados em docs; `generate_delivery_otp` é DB validado). Live: Sessões
    14 (n8n) + 15-16 (WhatsApp) + 17-19 (app Next.js/Storage API).
  - **Veredito**: GO para Sessão 13 (n8n: arquitetura dos workflows).
- **Próxima**: Sessão 13 — n8n: arquitetura dos workflows (design dos 16 workflows,
  trigger/input/validações/operações/chamadas ao backend/eventos/retries/idempotência).

## Roadmap (20 fases / 29 sessões)

| Fase | Sessões | Entrega | Gate |
|---|---|---|---|
| 0. Fundação | 01–02 | Diagnóstico + documentação-mãe + ADRs | — |
| 1. Cérebro | 03–04 | Banco completo + Auth/RLS/RBAC | — |
| 2. Criação da corrida | 05–06 | Empresas/entregadores/veículos + delivery_request | — |
| 3. Preço | 07 | Pricing engine determinístico | — |
| 4. Dispatch | 08 | Busca de candidatos + raio progressivo | — |
| 5. Lances | 09–10 | Bid engine + **atribuição atômica** | ✅ GATE (10) |
| 6. Ciclo completo | 11–12 | Máquina de estados + proof of delivery | — |
| 7. n8n | 13–14 | Arquitetura + workflows | — |
| 8. DataCrazy + WhatsApp | 15–16 | Agente de pedidos + notificações de oportunidade | — |
| 9. PWA entregador | 17 | Interface mobile do entregador | — |
| 10. Painel operacional | 18 | Dashboard ViO10 | — |
| 11. Portal empresa | 19 | Portal do cliente | — |
| 12. Mapas/RT | 20 | Geo, rotas, ETA, mapa operacional | — |
| 13. Financeiro | 21 | Ledger + cobrança/repasse idempotente | — |
| 14. Segurança | 22 | Security review completo | ✅ |
| 15. QA | 23 | E2E + cenários negativos | — |
| 16. Correção | 24 | P0/P1 zerados | ✅ GATE (24) |
| 17. Staging | 25 | Ambiente de homologação | — |
| 18. Piloto | 26 | Shadow mode + feature flags + kill switches + métricas | ✅ |
| 19. Produção | 27 | Go/no-go + deploy controlado | ✅ GATE final (27) |
| 20. Encerramento | 28–29 | Code review final + postmortem | — |

## Regras de execução

- Uma sessão por vez; validar antes de avançar.
- Em funcionalidades maiores, gerar `PLAN.md` e executar em partes.
- Gates de produção (10, 24, 27) não são negociáveis.
- Ordem interna por feature: backend → regras → APIs → permissões → testes → interface.

## Próxima sessão — Sessão 03: Banco de Dados

Antes de modelar:
1. Releitura de `CLAUDE.md`, `ARCHITECTURE.md`, `BACKEND.md`, `PLAN.md`, ADRs.
2. Verificar migrations existentes (nenhuma ainda).
3. Produzir o plano da modelagem antes de executar.

Entregar: modelo, relacionamentos, migrations, constraints, índices, políticas de
acesso, testes do banco, riscos. **Não criar frontend.** A regra crítica (uma
`delivery_request` não pode ter duas atribuições ativas) deve estar protegida no
banco desde esta sessão, não esperar a Sessão 10.