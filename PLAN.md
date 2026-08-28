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
- **Próxima**: Sessão 04 — Autenticação, RLS e RBAC (grants least-privilege por
  função/tabela + policies RLS + RBAC).

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