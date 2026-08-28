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

- disponível (`driver_availability = available`);
- veículo compatível com o exigido na corrida;
- dentro da área operacional (`service_areas`);
- distância aceitável até a coleta (raio da rodada);
- sem corrida incompatível em andamento;
- conta habilitada.

## Raio progressivo

Rodadas expandem o raio configuravelmente:

- rodada 1 → raio menor;
- rodada 2 → raio intermediário;
- rodada 3 → raio maior.

Números não são hardcoded; vêm de configuração por `service_area` / `pricing_rules`.
Limite máximo de rodadas e raio máximo também configuráveis.

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