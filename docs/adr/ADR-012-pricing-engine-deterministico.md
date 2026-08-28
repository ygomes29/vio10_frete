# ADR-012 — Pricing engine determinístico (cotação, `draft → quoted`)

- **Status**: Aprovado
- **Data**: 2026-08-28
- **Sessão**: 07

## Contexto

A Sessão 06 entrega a corrida em `draft` (sem preço; ADR-011 D1). A Sessão 07 é a Fase 3
do roadmap ("Preço"): implementa o **motor determinístico de pricing**. Dada uma
`delivery_request` em `draft` + distância/duração reais, calcula a cotação, escreve o
snapshot em `delivery_quotes` (0008) e dispara `draft → quoted` via `transition_delivery`
(0016, que já tem essa transição na matriz e emite `quote_created` + seta `quoted_at`).

Tudo o que o motor precisa já existe no schema: `pricing_rules` (config por
`organization_id` + `vehicle_type`, 0008), `delivery_quotes` (snapshot, 0008),
`transition_delivery` (0016), enums `vehicle_type`/`delivery_priority`/`quote_status`
(0002). **Nenhuma RPC de pricing existia** — a Sessão 07 cria a primeira, `create_quote`.

`docs/PRICING_ENGINE.md` estabelece os princípios: pricing é **determinístico e
configurável**; **IA não define preço** — o valor cobrado/devido vem do motor. Dinheiro em
**centavos inteiros** (ADR-008). O doc lista os componentes (`base`, `distance_component`,
`vehicle_component`, `urgency_component`, `dynamic_component`, `subtotal`,
`platform_fee`, `driver_offer`, `customer_price`) e um exemplo, mas **não escreve a
álgebra** — a Sessão 07 a formaliza (D2).

### Decisões de usuário (confirmadas no planejamento da Sessão 07)
- **Origem da rota**: `create_quote` recebe `p_distance_meters` + `p_duration_seconds`
  como parâmetros do backend (system-scoped). O provider real (Google Maps Routes,
  `TWO_WHEELER`) é referência para a **Sessão 20**; o motor é cálculo puro. PostGIS
  haversine é proibido para cobrança ("rota real, não linha reta", `GEOLOCATION.md`).
- **Faixa de preço = min/max real**: o motor calcula piso+teto (não cotação única).
  Adiciona colunas min/max em `delivery_quotes` + multipliers em `pricing_rules`.
- **Álgebra** (confirmada pelo exemplo do doc: subtotal=1020, fee=120, driver_offer=900,
  customer_price=1140): `customer_price = subtotal + platform_fee`;
  `driver_offer = subtotal − platform_fee`; margem plataforma =
  `customer_price − driver_offer = 2 × platform_fee` (fee cobrado dos dois lados).

## Decisões

### D1 — `create_quote` é system-scoped apenas (primeiro RPC system-only)

`auth.uid() IS NOT NULL` → `not_authorized`. Só o backend (`service_role`, system path)
chama. **Motivo (trust boundary):** a distância/duração são **insumos do cálculo** e vêm
do provider de rota (plataforma), não do business. Se um business autenticado passasse
`p_distance_meters`, poderia forjar uma distância pequena → preço baixo. System-only
garante que os insumos vêm de fonte confiável (backend → provider Sessão 20).

Distinto de `create_delivery_request` (ADR-011 D4 permite org member): os endereços da
corrida são do business (legítimos); a distância é da plataforma. O dashboard "solicitar
cotação" chama um Route Handler do backend, que chama `create_quote` system-scoped
(Sessão 18) — o backend não expõe o input de pricing ao cliente.

**Grants**: `revoke all from public`; `grant execute to service_role` **somente** —
`authenticated` **nem EXECUTE** recebe (defesa em profundidade: bloqueio no nível de
privilégio antes da checagem interna de `auth.uid()`). `anon`: nada.

### D2 — Álgebra determinística (do exemplo do doc)

```
base               = rule.base_cents
distance_component = (rule.per_km_cents * p_distance_meters + 999) / 1000   -- ceil inteiro, sem float
vehicle_component  = 0    -- MVP: custo do veículo já no base/per_km da regra por vehicle_type
urgency_component  = case priority when 'urgent' then rule.urgency_add_cents else 0 end
dynamic_component  = 0    -- MVP: demanda/pico deferido (sem coluna de config no schema)
subtotal_raw       = base + distance_component + vehicle_component + urgency_component + dynamic_component
subtotal           = greatest(subtotal_raw, rule.min_price_cents)   -- piso da corrida
platform_fee       = rule.platform_fee_cents
customer_price     = subtotal + platform_fee
driver_offer       = subtotal - platform_fee        -- se < 0 -> pricing_error (regra mal-config)
```

Tudo em `bigint` cents (ADR-008). `distance_component` por divisão inteira com ceil
(`(per_km_cents * meters + 999) / 1000`) — nenhum float no caminho do dinheiro.
`vehicle_component` e `dynamic_component` ficam **0 no MVP**: o custo do veículo é
codificado pela seleção da regra por `vehicle_type` (`base_cents`/`per_km_cents` diferem
por veículo); demanda/horário/pico são deferidos (sem coluna de config). O snapshot em
`delivery_quotes` registra esses componentes como 0 (explícito, não implícito).

`min_price_cents` é piso do **subtotal** (não do customer_price): se `subtotal_raw <
min_price_cents`, `subtotal = min_price_cents`, e `customer_price`/`driver_offer`
rederivados — preserva a álgebra e a margem.

### D3 — Faixa min/max real (piso+teto) via multipliers configuráveis

`pricing_rules` ganha `min_multiplier numeric(5,4)` e `max_multiplier numeric(5,4)`
(ambos `> 0`, `min <= max`, default `1.0`). O motor deriva a faixa do preço-alvo:

```
min_customer_price = greatest(rule.min_price_cents, floor(customer_price * min_multiplier))
max_customer_price = ceil(customer_price * max_multiplier)
min_driver_offer   = floor(driver_offer * min_multiplier)   -- floor 0
max_driver_offer   = ceil(driver_offer * max_multiplier)
```

`numeric` (não float) para o produto; `floor`/`ceil` → `bigint`. Default `1.0/1.0` → faixa
degenerada (min=max=alvo); orgs configuram uma banda real (ex.: `0.95/1.05`).

**Semântica:**
- **`customer_price` / `driver_offer`** = alvo determinístico (o "meio" da faixa).
- **`min/max_customer_price`** = faixa mostrada ao business ("preço entre X e Y").
- **`min/max_driver_offer`** = banda aceitável para lances do entregador (enforcement no
  bid engine, Sessão 09); o `driver_offer` é a base, o entregador aceita ou envia
  `counter_bid` dentro da banda.

### D4 — Seleção de regra: org-specific → fallback global

```
where organization_id = p_org and vehicle_type = delivery.vehicle_required
  and is_active and effective_from <= now()
order by effective_from desc limit 1
```
Se não houver regra da org, fallback para regra global (`organization_id is null`) do
mesmo `vehicle_type`. Se nenhuma → `no_pricing_rule`. Regras por `vehicle_type` (moto vs
carro) já são linhas distintas — a seleção por veículo é natural. `effective_from`
suporta versionamento temporal (regra mais recente vigente).

### D5 — Atomicidade: transition FIRST, quote insert AFTER

`create_quote` é uma transação `SECURITY DEFINER`:
1. Valida (delivery existe, `status='draft'`, inputs > 0).
2. Seleciona regra (D4), computa (D2), deriva faixa (D3).
3. Gera `v_quote_id := gen_random_uuid()`.
4. Chama `transition_delivery(p_id, 'quoted', 'system', null,
   jsonb_build_object(quote_id, customer_price_cents, driver_offer_cents,
   pricing_rule_id), p_correlation_id)` — atomicamente: `select ... for update` checa
   `status='draft'`, transita, seta `quoted_at`, emite `quote_created`.
5. Se `not ok` → retorna `(false, reason)` **sem** insertar quote (sem órfão; ex.:
   `wrong_state` se status mudou concorrentemente).
6. Se `ok` → inserta `delivery_quotes` (id=`v_quote_id`, status='pending',
   `expires_at=now()+900s`, snapshot completo: todos componentes + alvo + min/max +
   `distance_meters` + `duration_seconds` + `pricing_rule_id`).
7. Retorna `(true, 'quoted', v_quote_id)`.

Se o insert falhar (ex.: constraint), a tx toda roll back — a transição é desfeita.
Externamente atômico: ninguém observa `quoted` sem quote (tudo no mesmo commit). A ordem
transition-first evita quote órfã em race (concorrente cota a mesma `draft` → a primeira
transita; a segunda recebe `wrong_state` e não inserta).

### D6 — Capture de ator via `auth.uid()` (igual ADR-011 D6 / transition_delivery)

Como `create_quote` é system-only, o ator do evento `quote_created` é `'system'`
(`auth.uid()` null). `transition_delivery` deriva o ator de `auth.uid()` (não confia nos
params); no path system, `actor_type='system'`, `actor_id=null`. Ator nunca vem de param
do `create_quote`.

### D7 — Quote TTL e lifecycle da quote

`expires_at = now() + 900s` (15 min, **constante no MVP**; TTL configurável por org é
deferido). `status='pending'` na criação. `confirmed_at`/`status='confirmed'` é setado
quando `quoted → searching_driver` (dispatch, Sessão 08) — **não** na Sessão 07. Re-quote
de uma corrida já `quoted` → `wrong_state` (só cota `draft`); re-quote de quote expirada é
fluxo da Sessão 11–12 (fora de escopo). `superseded` existe no enum mas não é usado no MVP.

### D8 — Idempotência por estado (não por chave)

`create_quote` não tem `external_reference` nem `idempotency_key`. Re-chamada para a
mesma corrida `draft` após sucesso → `wrong_state` (status virou `quoted` — guardado por
`transition_delivery` via `for update`). Retries de API/integration (mesma operação
re-enviada) ficam com `integration_events.idempotency_key` (Sessão 13). Para MVP, a
guarda é o estado (`draft`): idempotente por estado, não por chave.

## Consequências

- **0022** altera `pricing_rules` (+`min_multiplier`, `max_multiplier`) e `delivery_quotes`
  (+`min/max_customer_price_cents`, `min/max_driver_offer_cents`) e cria `create_quote`
  RPC `SECURITY DEFINER` system-only. **Nenhuma tabela nova.**
- Sem novos grants de DML a `authenticated`; `authenticated` mantém SELECT sob RLS
  (0017) em `delivery_quotes`/`pricing_rules`. Único grant novo: `execute on create_quote
  to service_role`. `anon`: nada.
- **Defesa em profundidade**: a cotação é imposta no banco (RPC DEFINER system-only
  valida inputs e transita atomicamente) e o backend obtém a rota de fonte confiável
  (provider Sessão 20). O business não toca nos insumos de pricing.
- **`draft → quoted` só via `create_quote`**: embora `transition_delivery` aceite
  `draft → quoted` para system/admin/org-member, o caminho legítimo de pricing é
  `create_quote` (que valida a regra e snapshot). Chamar `transition_delivery('quoted')`
  direto criaria `quoted` sem quote — não é bloqueado no banco no MVP (deferido: guard
  de que `quoted` implica quote existe), mas é contrato da camada de serviço usar
  `create_quote`.

## Fora do escopo (adiado)

- **Provider de rota real** (Google Maps Routes, `TWO_WHEELER`, ETA) → **Sessão 20**. A
  Sessão 07 recebe distância/duração do backend.
- **Dispatch** (busca de candidatos, `service_areas` management, raio progressivo) →
  Sessão 08. `quoted → searching_driver` (confirma quote, seta `confirmed_at`) é lá.
- **`dynamic_component`** (demanda/horário/pico) → deferido (0 no MVP); sem coluna de
  config no schema.
- **`weight_g`/dims no preço** → MVP: só capacity/eligibility no dispatch (Sessão 08).
- **distância entregador→coleta** no quote → sem driver atribuído em `draft → quoted`;
  fica no dispatch/scoring (Sessão 08).
- **Re-quote / `superseded`** / TTL configurável por org / `confirmed_at` lifecycle /
  guard de `quoted` implica quote → Sessão 08 (dispatch) / 11–12 (máquina de estados).
- **Rate limiting de cotação** → camada de serviço/API (Sessão 22).

## Referências

`ADR-008` (centavos inteiros), `ADR-009` (RBAC), `ADR-011` (criação=`draft` sem preço),
`docs/PRICING_ENGINE.md` (componentes, exemplo), `docs/DELIVERY_LIFECYCLE.md`
(`draft → quoted` = sistema/pricing), `docs/GEOLOCATION.md` (provider de rota, Sessão 20),
`docs/SECURITY.md` (R17, system-only), `0008_pricing.sql` (`pricing_rules`,
`delivery_quotes`), `0016_rpcs_security_definer.sql` (`transition_delivery` matriz +
`quoted_at` + `quote_created`), `0002_enums.sql` (`vehicle_type`, `delivery_priority`,
`quote_status`).