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
- **Próxima**: Sessão 10 — atribuição atômica em **concorrência real** (harness via
  `dblink`/paralelismo, greenfield, ADR-007) — **GATE de produção**.

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