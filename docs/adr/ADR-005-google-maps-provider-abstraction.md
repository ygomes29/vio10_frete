# ADR-005 — Google Maps atrás de provider abstraction

- **Status**: Aprovado
- **Data**: 2026-08-27
- **Sessão**: 02

## Contexto

O ViO10 precisa de geocodificação, validação de endereço, distância de rota real,
duração estimada e rota para motos. A Sessão 01 propôs OSRM self-hosted como
dependência inicial; reconsiderado: o valor da Routes API do Google com
`TWO_WHEELER` no Brasil é decisivo para o caso de uso (motociclistas).

## Decisão

Provider geográfico inicial: **Google Maps Platform**, acessado **somente** via
abstrações `GeocodingProvider` e `RoutingProvider`. O domínio **nunca** chama o
Google diretamente. Isso permite trocar/complementar futuramente com OSRM, Mapbox
ou outro provider sem alterar o domínio.

## Consequências

- Suporte a `TWO_WHEELER` desde o início (essencial para motos no Brasil).
- Custo do Google controlado por cache quando seguro; documentar limites/quotas.
- Distância cobrada em corrida usa **rota real**, não linha reta.
- OSRM deixa de ser dependência obrigatória inicial; pode ser complemento futuro.

## Referências

`docs/GEOLOCATION.md`.
Fonte: [Two-wheeled vehicles — Routes API](https://developers.google.com/maps/documentation/routes/coverage-two-wheled?hl=en).