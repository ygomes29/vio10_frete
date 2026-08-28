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

## Testes (Sessão 07)

Casos: distâncias curtas/médias/longas; moto vs carro; urgência vs não; valor
mínimo acionado; horário fora/dentro; composição explicável e consistente.