# docs/PRICING_ENGINE.md — Motor de preços

> Documento de referência para a Sessão 07.

## Princípio

Pricing é **determinístico e configurável**. **IA não define preço arbitrariamente.**
A IA pode interpretar linguagem e sugerir, mas o valor cobrado/devido é calculado
pelo motor.

## Composição do preço

Componentes conceituais:

```
base
distance_component
vehicle_component
urgency_component
dynamic_component
subtotal
platform_fee
driver_offer          (remuneração ofertada ao entregador)
customer_price        (cobrado da empresa)
```

Sem surge pricing complexo no MVP. O motor precisa **explicar a composição** do
valor (cada componente no snapshot da cotação, para auditoria).

## Separação de valores

- **customer_price_cents** — cobrado da empresa.
- **driver_offer_cents** — remuneração ofertada ao entregador (base para a rodada).
- **driver_earning_cents** — valor devido ao entregador (pode diferir do offer
  após lance; ver `docs/BID_ENGINE.md`).
- **platform_fee_cents** — margem/taxa ViO10.

## Fatores

- tarifa base;
- distância (rota real, não linha reta);
- duração estimada;
- tipo de veículo;
- distância do entregador até a coleta (quando aplicável);
- urgência;
- horário;
- demanda (preparado, simples no MVP);
- valor mínimo / preço mínimo por corrida;
- taxa da plataforma.

## Regras configuráveis, não hardcoded

Valores e regras vivem em `pricing_rules` (ou equivalente), não espalhados no
código. Pesos e limites são configuráveis.

## Dinheiro

Tudo em centavos inteiros (`*_amount_cents`), currency `BRL`. Nunca float.

## Resposta interna (exemplo)

```
base               = 500
distance_component = 320
vehicle_component  = 200   (moto)
urgency_component   = 0
dynamic_component   = 0
subtotal            = 1020
platform_fee        = 120
driver_offer        = 900
customer_price      = 1140
```

(Valores ilustrativos; reais vêm de configuração.)

## Álgebra formal (implementada — Sessão 07, ADR-012)

O motor é a RPC `create_quote` (`0022_pricing_engine.sql`), `SECURITY DEFINER`
**system-only** (`auth.uid() IS NOT NULL` → `not_authorized`; só `service_role`).
Insumos de rota (distância/duração) vêm do backend (provider na Sessão 20), nunca do
business — trust boundary: se o business passasse a distância, forjaria preço baixo.

```
base               = rule.base_cents
distance_component = (rule.per_km_cents * p_distance_meters + 999) / 1000   -- ceil inteiro, SEM float
vehicle_component  = 0    -- MVP: custo do veículo no base/per_km da regra por vehicle_type
urgency_component  = case when priority='urgent' then rule.urgency_add_cents else 0 end
dynamic_component  = 0    -- MVP: demanda/pico deferido (sem coluna de config)
subtotal_raw       = base + distance_component + vehicle_component + urgency_component + dynamic_component
subtotal           = greatest(subtotal_raw, rule.min_price_cents)   -- piso do subtotal
platform_fee       = rule.platform_fee_cents
customer_price     = subtotal + platform_fee
driver_offer       = subtotal - platform_fee        -- se < 0 -> pricing_error (regra mal-config)
```

Margem plataforma = `customer_price − driver_offer = 2 × platform_fee` (fee dos dois
lados). Tudo em `bigint` cents (ADR-008); `distance_component` por divisão inteira com
ceil — nenhum float no caminho do dinheiro. `vehicle_component`/`dynamic_component`
ficam **0 no MVP** (explícito no snapshot, não implícito): o custo do veículo é
codificado pela seleção da regra por `vehicle_type` (base/per_km diferem); demanda/pico
são deferidos.

## Faixa min/max (banda de preço — ADR-012 D3)

O motor não retorna cotação única: retorna **piso+teto** derivados do alvo via
multipliers configuráveis em `pricing_rules` (`min_multiplier`, `max_multiplier`
numeric(5,4), default 1.0; `min ≤ max`):

```
min_customer_price = greatest(rule.min_price_cents, floor(customer_price * min_multiplier))
max_customer_price = ceil(customer_price * max_multiplier)
min_driver_offer   = greatest(0, floor(driver_offer * min_multiplier))
max_driver_offer   = ceil(driver_offer * max_multiplier)
```

`numeric` (não float) no produto; `floor`/`ceil` → `bigint`. Default 1.0/1.0 → faixa
degenerada (min=max=alvo); orgs configuram banda real (ex.: 0.90/1.10).

**Semântica:**
- **`customer_price` / `driver_offer`** = alvo determinístico (o "meio" da faixa).
- **`min/max_customer_price`** = faixa mostrada ao business ("preço entre X e Y").
- **`min/max_driver_offer`** = banda aceitável para lances do entregador (enforcement
  no bid engine, Sessão 09).

## Seleção de regra (Atribuição de ADR-012 D4)

Regra específica da org → fallback global → ausência:

```
1) where organization_id = delivery.organization_id
       and vehicle_type = delivery.vehicle_required
       and is_active and effective_from <= now()
   order by effective_from desc limit 1
2) se não houver: where organization_id is null and mesmo vehicle_type e ativa...
3) se nenhuma -> no_pricing_rule
```

Regras por `vehicle_type` (moto vs carro) são linhas distintas — a seleção por veículo é
natural. `effective_from` suporta versionamento temporal (regra mais recente vigente).

## Atomicidade e lifecycle (ADR-012 D5/D7/D8)

`create_quote` é uma transação `SECURITY DEFINER`: chama
`transition_delivery('quoted')` **antes** de insertar `delivery_quotes`; se a
transição falhar (ex.: `wrong_state` em race concorrente), retorna **sem** insertar
(sem quote órfã). Snapshot em `delivery_quotes` (`status='pending'`,
`expires_at = now()+900s`). `quoted_at`/evento `quote_created` são setados por
`transition_delivery` (0016). `confirmed_at`/`status='confirmed'` é setado em
`quoted → searching_driver` (dispatch, Sessão 08) — não na cotação. Re-cotar corrida já
`quoted` → `wrong_state` (idempotência por estado, sem `idempotency_key`).

## Testes (Sessão 07)

`supabase/tests/test_vio10_pricing.sql` — 62 asserções (begin/rollback + SELECT
consolidado), executadas **real** no dev `rtoyfiqngyicqtuzwfhz`. Casos: cotação moto
standard (componentes, subtotal, customer/driver, faixa min/max, snapshot,
status `quoted`, `quoted_at`, evento `quote_created` com `quote_id`); urgent vs
standard (urgency_component); carro vs moto (regra diferente); `min_price` floor;
faixa não-degenerada (multipliers 0.90/1.10); `driver_offer < 0` → `pricing_error`;
`no_pricing_rule`; fallback global; `wrong_state` (re-cotar já quoted);
`invalid_distance`/`invalid_duration`; authz (autenticado → `not_authorized`,
system → ok); `distance_component` ceil inteiro (1001m). **62/62 PASS (real)**.