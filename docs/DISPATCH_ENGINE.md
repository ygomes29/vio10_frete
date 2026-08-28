# docs/DISPATCH_ENGINE.md — Motor de despacho

> Documento de referência para a Sessão 08. Define a busca de candidatos e o
> ciclo das rodadas de dispatch. O **scoring e a atribuição** vivem em
> `docs/BID_ENGINE.md` — este doc cobre a **busca e a rodada**.

## Objetivo

Ao receber uma corrida elegível (`searching_driver`), localizar candidatos e abrir
rodadas de oferta até atribuir (ou expirar).

## Ciclo de uma dispatch round

```
delivery_request (searching_driver)
  → criar dispatch_round (nº, raio, timeout, driver_offer, critérios)
  → selecionar candidatos (eligibility)
  → criar delivery_offers (uma por candidato)
  → enviar ofertas via DataCrazy/WhatsApp (link assinado + expirável)
  → aguardar respostas durante janela configurada (timeout)
  → fechar rodada
  → BID ENGINE: coletar respostas válidas → scoring → candidato vencedor
  → claim_delivery() atômico
  → se ganhou: vencedor confirmado; expirar outras ofertas; notificar
  → se perdeu (indisponível/concorrência): tratar determinísticamente
  → se nenhum candidato aceitável: nova dispatch_round
```

## Critérios de eligibility (MVP)

Um driver é candidato sse **todos** (implementação ADR-013 D3, `open_dispatch_round`):

- `drivers.account_status = 'active'` (conta habilitada);
- `drivers.current_availability_status = 'available'` (disponível);
- `drivers.current_vehicle_id is not null` **e** `vehicles.vehicle_type =
  delivery.vehicle_required` (veículo compatível, join pelo veículo corrente);
- **sem assignment ativa**: `not exists (select 1 from delivery_assignments a where
  a.driver_id = drivers.id and a.status = 'active')` (sem corrida incompatível em
  andamento);
- localização fresca: `driver_locations.position is not null and captured_at >
  now() - p_max_location_age_seconds` (default 300s; conceito de `stale`);
- dentro do raio: `ST_DWithin(driver_locations.position, delivery.pickup_point,
  p_search_radius_m)` (geography, metros — proximidade operacional, **não** cobrança;
  distinto de pricing, onde haversine é proibido para cobrança).

Ordenação: `ST_Distance(driver_locations.position, pickup_point) ASC`, `LIMIT
p_max_candidates`. O índice GiST em `driver_locations.position` (0005) suporta a busca
espacial; o filtro de `vehicle_type`/assignment/frescor reduz o conjunto antes do
`LIMIT`.

**Filtro `service_areas` por entregador ADIADO no MVP** — não há junction
driver↔area hoje; o raio até a coleta é a única restrição espacial no dispatch. **Capacidade/
pesco/dims ADIADO** — só `vehicle_type` no MVP; `weight_g`/dims ficam no scoring futuro
(Sessão 09). **Não muta `current_availability_status` ao criar offers** — o valor `offered`
do enum é **reservado**, não usado no MVP; o driver permanece `available` e pode receber
offers de rodadas distintas. O guard contra dupla offer do mesmo driver na mesma rodada é
o UK `(dispatch_round_id, driver_id)` de `delivery_offers`.

## Raio progressivo

Rodadas expandem o raio configuravelmente:

- rodada 1 → raio menor;
- rodada 2 → raio intermediário;
- rodada 3 → raio maior.

Números não são hardcoded; vêm de configuração (no MVP, parâmetros do backend/orquestrador;
`tabela dispatch_config` adiada). Limite máximo de rodadas e raio máximo também
configuráveis.

**Implementação (ADR-013 D5):** o raio progressivo é **orquestrado**, não no RPC.
`open_dispatch_round` abre **uma rodada** por chamada com os params dados (raio,
max_candidates, driver_offer, janela). A sequência crescente de raios e o limite de
rodadas/raio máximo são decididos pelo **orquestrador** (backend/n8n, Sessões 13-14) —
que fecha a rodada anterior (Sessão 09, scoring/seleção) antes de abrir a próxima. O guard
`round_already_open` impede abrir a próxima enquanto há rodada aberta. `round_number` é
monotônico por corrida (snapshot de cada tentativa). A composicionalidade (chamar N vezes
com raios crescentes) é o motivo de `open_dispatch_round` ser **system-only** e stateless
quanto à sequência — os insumos de dispatch vêm do backend, não do business.

## Parâmetros configuráveis por rodada

A nova rodada pode alterar (tudo configurável, não arbitrário):

- raio;
- quantidade de candidatos;
- `driver_offer_cents`;
- timeout (janela de resposta);
- critérios de eligibility/scoring.

## Preparado para o futuro (não usar no MVP)

Fatores como rating, taxa de conclusão, cancelamentos, velocidade de resposta,
performance histórica ficam **no modelo** mas não são usados enquanto não houver
dados confiáveis. Ver `docs/BID_ENGINE.md` (scoring).

## Limites e kill switches

- Limite de rodadas por corrida.
- Kill switch do dispatcher (desligar despacho automático — ver Sessão 26).
- Limite de raio, de valor e de corridas simultâneas no piloto.

## Observabilidade

Cada rodada registra: nº, raio, candidatos convidados, respostas recebidas, timeout,
resultado, `correlation_id`, `delivery_request_id`.

## Implementação (Sessão 08, ADR-013)

Dois movimentos, dois RPCs, duas trust boundaries:

1. **`confirm_quote`** (user-scoped, `SECURITY DEFINER`) — business/operator/admin/membro
   da org confirma a cotação pendente: valida `status='quoted'` + `delivery_quotes.status=
   'pending'` não expirada; **transition-first** `quoted → searching_driver` (via
   `transition_delivery`, que emite `dispatch_started` e seta `dispatch_started_at`); se
   ok, marca a quote `confirmed` + `confirmed_at`, emite `quote_confirmed`. Se a transição
   falhar (race → `wrong_state`), retorna **sem** marcar confirmed (sem quote confirmed
   órfã). Idempotência por estado: re-confirmar → `wrong_state`. Grants: `service_role` +
   `authenticated` (user-facing); `anon`: nada.

2. **`open_dispatch_round`** (system-only, `SECURITY DEFINER`, segundo system-only após
   `create_quote`) — o orquestrador (backend) abre uma rodada: valida `searching_driver` +
   params + `round_already_open` guard; cria `dispatch_round` (round_number monotônico,
   `config_snapshot`, `expires_at`) + `delivery_offers` por candidato elegível (D3,
   atomicamente); emite `round_opened` + `offer_created` (ator `'system'`). Retorna
   `(ok, reason, round_id, candidate_count)` — **cria a rodada mesmo com 0 candidatos**
   (audit: snapshot da tentativa no raio; o orquestrador sabe expandir). Grants:
   `service_role` **somente** (`authenticated` sem EXECUTE — defesa em profundidade);
   `anon`: nada. Trust boundary: raio/candidatos/oferta são insumos do backend, não do
   business — um business passando `p_search_radius_m`/`p_driver_offer_cents` forjaria a
   busca/oferta.

**Nenhuma tabela/coluna nova** — tudo já existe em 0005/0009/0010. RLS SELECT em
`dispatch_rounds`/`delivery_offers` já existe (0017, via `can_view_delivery_request`);
`service_role` DML já existe (0015). Sem novos grants de DML a `authenticated`.

**Fora do escopo (Sessão 09-10, GATE):** fechar rodada, coletar respostas, pontuar,
escolher vencedor, `claim_delivery` atômico. `respond_to_offer` (0013) já registra
respostas; `claim_delivery` (0013) já atribui. A Sessão 08 só **abre** rodadas + cria
offers.