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
| `docs/SECURITY.md` | RLS, authz, idempotência, links assinados, secrets |
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
- **Próxima**: Sessão 04 — Autenticação, RLS policies, grants least-privilege e RBAC.

Ver `PLAN.md` para o roadmap completo e `CHANGELOG.md` para o histórico.