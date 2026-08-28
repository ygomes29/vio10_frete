# CLAUDE.md — Guia do projeto ViO10

> Este arquivo é o ponto de entrada para qualquer sessão do Claude Code neste repositório.
> Ele carrega o contexto mínimo necessário para entender o ViO10 e trabalhar de forma
> consistente. Documentação detalhada vive nos arquivos referenciados abaixo.

## O que é o ViO10

O ViO10 é uma **plataforma de logística local e fretes rápidos**. O objetivo inicial é
operar em **Congonhas/MG**, conectando estabelecimentos comerciais locais a entregadores
(prioritariamente motociclistas) para entregas rápidas de produtos.

Não é um delivery de alimentos. É um **motor inteligente de despacho e contratação de
fretes locais**.

Fluxo macro: empresa solicita → sistema entende origem/destino/produto/urgência/veículo →
calcula faixa de preço → localiza entregadores elegíveis → oferece oportunidade →
entregadores aceitam o valor **ou enviam um lance** → sistema avalia candidatos → **um**
entregador recebe a corrida (atomicamente) → acompanha coleta e entrega → conclui e
registra.

## Regra mestra (leia antes de qualquer decisão técnica)

> **Banco é a fonte da verdade. Backend decide. n8n orquestra. IA interpreta.
> DataCrazy comunica. Frontend apresenta e coleta ações.**

- Nenhuma camada externa altera diretamente estado operacional/financeiro crítico.
- n8n e DataCrazy **não** escrevem no banco diretamente. Eles chamam o backend.
- IA não inventa preço, ETA, entregador ou status. Esses dados vêm do sistema.
- Frontend nunca inventa estado; consome estado oficial do backend.

## Stack aprovada

- **Next.js 16.3.3** (Active LTS) — App Router, TypeScript, Tailwind CSS, shadcn/ui.
  Não usar Next.js 15 como base greenfield. Confirmar patch 16.x mais recente no momento
  de inicializar dependências; sem versões beta/canary sem justificativa.
- **Supabase** — PostgreSQL + Auth + Storage + RLS + Realtime.
- **n8n** self-hosted — orquestrador, **não** fonte da verdade.
- **DataCrazy / WhatsApp** (Crazy IA) — mensageria e IA conversacional.
- **Google Maps Platform** — provider geográfico inicial, atrás de abstração.

Dinheiro sempre em **inteiros (centavos)**. `R$ 10,90 = 1090`. Nunca float para finança.

## Camadas e fronteiras

```
UI (React/Next) → application/service → domain → persistence/RPC (Postgres)
```

- **Route Handlers/API** para integrações externas (n8n, DataCrazy).
- **Server Actions** somente para ações originadas no próprio frontend.
- **Funções/RPC do Postgres** para operações que exigem atomicidade
  (atribuição de corrida, transições de estado críticas).
- n8n e DataCrazy **não** dependem de Server Actions internas.

## Tenancy

`organization` (tenant / conta contratante, limite primário de RLS)
→ `business` (negócio/marca operado pelo tenant)
→ `business_location` (unidade física).

MVP normalmente 1:1:1, mas o modelo suporta multi-unidade sem reconstrução.

## Estados da corrida

`draft → quoted → searching_driver → assigned → driver_to_pickup → at_pickup →
picked_up → in_transit → delivered` (+ terminais `cancelled`, `failed`, `expired`).

**`bidding` NÃO é estado principal.** A disputa ocorre *dentro* de `searching_driver`,
via `dispatch_rounds` / `delivery_offers` / `bids`.

### Semântica do sistema de lances (correção crítica da Sessão 01)

> **ACEITAR ≠ GANHAR.** ACEITAR = "estou disposto a fazer a corrida pelo valor ofertado",
> i.e. um lance igual a `driver_offer_cents`.

- O primeiro a clicar ACEITAR **não** ganha automaticamente.
- A rodada coleta candidatos numa janela configurada, fecha, pontua, escolhe o
  vencedor e só então executa `claim_delivery()` atomicamente.
- Early close futuro só por regra determinística explícita (ex.: `candidate_score >=
  fast_accept_threshold`), nunca "primeiro que aceitar ganha".

## Convenções do repositório

- Commits e documentação em **português**.
- Toda decisão arquitetural relevante vira um **ADR** em `docs/adr/`.
- Toda transição crítica de corrida passa por função central transacional — ninguém
  seta `status` direto no banco via app.
- Webhooks/mensagens/pagamentos são **idempotentes** (`idempotency_key`,
  `external_event_id`).
- Toda alteração relevante em corrida gera `delivery_event` (auditoria).

## Documentação

| Arquivo | Conteúdo |
|---|---|
| `ARCHITECTURE.md` | Arquitetura completa, camadas, fronteiras, diagramas |
| `BACKEND.md` | Estrutura do backend, layering, RPC, idempotência |
| `FRONTEND.md` | 3 superfícies (driver/admin/business), PWA, convenções |
| `PLAN.md` | Roadmap por fases, status atual, próxima etapa |
| `CODE_REVIEW.md` | Log de revisões e security review |
| `CHANGELOG.md` | Histórico de mudanças |
| `docs/PRODUCT.md` | Produto, escopo MVP, usuários, fluxos |
| `docs/DELIVERY_LIFECYCLE.md` | Máquina de estados da entrega |
| `docs/DISPATCH_ENGINE.md` | Busca de candidatos, rodadas, raio progressivo |
| `docs/BID_ENGINE.md` | Semântica de ACEITAR/lance, scoring, atribuição |
| `docs/PRICING_ENGINE.md` | Pricing determinístico, composição do preço |
| `docs/N8N_WORKFLOWS.md` | Mapa de workflows n8n |
| `docs/DATACRAZY_INTEGRATION.md` | Limites DataCrazy/IA, fluxos WhatsApp |
| `docs/SECURITY.md` | RLS, authz, idempotência, auth/convite, links assinados, secrets |
| `docs/GEOLOCATION.md` | Abstração de provider, Google Maps, TWO_WHEELER |
| `docs/DECISIONS.md` | Log consolidado de decisões |
| `docs/adr/` | ADRs ADR-001 em diante |

## Estado atual

- **Sessão 01**: diagnóstico aprovado.
- **Sessão 02**: fundação documental (docs-mãe + ADRs).
- **Sessão 03**: fundação do banco (14 migrations, 4 RPCs, RLS default deny).
- **Sessão 03.5 (concluída)**: validação real da fundação — **PASS**. Testes
  executados server-side (sem Docker): pgTAP 12/12, RPCs 48/48, concorrência
  `claim_delivery` (exatamente 1 vencedor), `delivery_events` imutável, RLS e grants
  default-deny confirmados. Correções: PostGIS search_path, 0014 endurecido (auto-grants
  Supabase), R16 cross-round, R17 (`external_reference` ≠ `idempotency_key`),
  `service_role` user-scoped vs system-scoped.
- **Sessão 04 (concluída)**: Auth/Grants/RLS/RBAC — **PASS (Modelo B)**. 17 migrations
  (0016 RPCs `SECURITY DEFINER` + checagem `auth.uid()`; 0017 RLS policies + 5 helpers
  DEFINER). ADR-009 matriz RBAC. Grants least-privilege (0015). Validado real no dev:
  authz 21/21, system-path claim 4/4, R16 cross-round, concorrência exatamente 1
  vencedor, bypass PostgREST FECHADO, inventário consistente.
- **Sessão 05 (concluída)**: Auth de usuários (Supabase Auth) + reset/replay
  from-scratch — **PASS**. 19 migrations (0018 trigger `handle_new_user` DEFINER on
  `auth.users` AFTER INSERT → `profiles`; 0019 `invitations` + 6 RPCs DEFINER de
  identidade/convite + helpers `my_email()`, `is_super_or_admin()`). ADR-010 (email+senha,
  trigger de perfil, convites com prova de email via login, JWT DB-lookup sem custom
  claims, cookie-based). `config.toml` (senha forte 12, sem anon/phone). Bug de
  escalonamento de privilégio corrigido na validação: mutação usava `is_platform_admin()`
  (inclui `operator`) → `is_super_or_admin()` (super/admin); visibilidade mantém
  `is_platform_admin()` (ADR-010 D4.1). Hardening final: reset via SQL + replay
  0001→0019 limpo (19/19); invariants 13/13, rpcs 48/48, authz 21/21, auth_lifecycle
  34/34 PASS. Risco "reset/replay não executado" (Sessão 04) FECHADO.
- **Sessão 06 (concluída)**: Criação da corrida + gestão de empresas/veículos/
  entregadores — **PASS**. 21 migrations (**0020** 6 RPCs DEFINER de gestão +
  `idx_vehicles_plate_uk`; **0021** `create_delivery_request` DEFINER). ADR-011
  (criação=`draft`+itens+evento `delivery_created`, sem preço; snapshots auto-contidos;
  pontos PostGIS server-side; `external_reference`=dedup; matriz de autoridade D4;
  mutação só via RPC DEFINER; capture de ator por `auth.uid()`). `update_driver_status`
  (super/admin, sem system) fecha o lado driver do risco offboarding. Nenhuma tabela
  nova. Hardening: reset via SQL + replay 0001→0021 limpo (21/21); invariants 13/13,
  rpcs 48/48, authz 21/21, auth_lifecycle 34/34, creation 37/37 PASS. Bug T4 corrigido
  na validação (JWT residual em `create_vehicle`).
- **Sessão 07 (concluída)**: Pricing engine determinístico (cotação, `draft → quoted`)
  — **PASS**. 22 migrations (**0022** `create_quote` DEFINER; altera `pricing_rules`
  +`min/max_multiplier` e `delivery_quotes` +min/max customer/driver; **nenhuma tabela
  nova**). ADR-012 (D1 `create_quote` **system-only** — primeiro RPC system-only,
  `auth.uid() not null`→`not_authorized`, trust boundary de insumos de rota do backend;
  D2 álgebra `customer=subtotal+fee`/`driver=subtotal−fee`, `distance_component` ceil
  inteiro, `vehicle`/`dynamic`=0 no MVP; D3 faixa min/max via multipliers; D4 regra
  org→global→`no_pricing_rule`; D5 atomicidade transition-first; D6 ator via `auth.uid`;
  D7 TTL 900s `pending`; D8 idempotência por estado). Grants: `revoke public` + `execute`
  só a `service_role` (`authenticated` sem EXECUTE; `anon` nada). Hardening: reset via
  SQL + replay 0001→0022 limpo (22/22); invariants 13/13, rpcs 48/48, authz 21/21,
  auth_lifecycle 34/34, creation 37/37, pricing 62/62 PASS. Bug de ambiguidade PL/pgSQL
  corrigido na validação (`select ok, reason`→ alias `t.ok, t.reason` — colunas de saída
  de `returns table` viram variáveis implícitas).
- **Sessão 08 (concluída)**: Dispatch engine (busca de candidatos + raio progressivo,
  `quoted → searching_driver`) — **PASS**. 23 migrations (**0023** 2 RPCs DEFINER:
  `confirm_quote` user-scoped + `open_dispatch_round` system-only; **nenhuma tabela nova**).
  ADR-013 (D1 `confirm_quote` user-scoped confirma cotação pendente, transition-first,
  marca quote `confirmed`+`confirmed_at`; D2 `open_dispatch_round` system-only, segundo
  system-only, trust boundary de insumos de dispatch; D3 eligibility MVP —
  active+available+veículo compatível+sem assignment ativa+localização fresca+`ST_DWithin`
  no raio, `service_areas` por entregador adiado; D4 criação atômica de rodada+offers; D5
  raio progressivo orquestrado; D6 atomicidade/guards; D7 ator via `auth.uid`; D8 sem
  novos grants de DML a `authenticated`, sem tabela nova). `offered` reservado (não muta
  availability; guard dupla offer = UK round+driver). Hardening: reset via SQL + replay
  0001→0023 limpo (23/23); invariants 13/13, rpcs 48/48, authz 21/21, auth_lifecycle 34/34,
  creation 37/37, pricing 62/62, dispatch 65/65 PASS. Lições da Sessão 07 (ambiguidade
  `as t` + PostGIS em `extensions` não `public`) aplicadas proativamente — nenhum bug em
  runtime. pgTAP `finish()` neste dev emite via RAISE (0 rows); `num_failed()=0` é a
  autoridade.
- **Próxima**: Sessão 09 — bid engine (scoring + seleção + `claim_delivery` atômico;
  `searching_driver → assigned`) — **GATE**.

Ver `PLAN.md` para o roadmap completo e `CHANGELOG.md` para o histórico.