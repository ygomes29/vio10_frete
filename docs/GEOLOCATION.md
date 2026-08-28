# docs/GEOLOCATION.md — Geolocalização e rotas

> Documento de referência para a Sessão 20. Fixa a **abstração de provider**
> aprovada na Sessão 02 (ADR-005).

## Princípio

O domínio **nunca** chama o Google Maps diretamente. Todo acesso a geolocalização
passa por uma **abstração de provider**. Isso permite trocar/complementar o provider
no futuro (OSRM, Mapbox, outro) sem mexer no domínio.

## Provider inicial

**Google Maps Platform** (atrás da abstração). Motivo-chave para o ViO10: a Routes
API oferece **`TWO_WHEELER`** no Brasil, específico para motos — essencial para
entregadores motociclistas.

Fonte: [Países com suporte a two-wheeled vehicles — Route API](https://developers.google.com/maps/documentation/routes/coverage-two-wheled?hl=en).

## PostGIS (Sessão 03)

PostGIS habilitado para **pré-filtro** (não substitui routing): `geography(Point,4326)`
em `driver_locations`, `service_areas`, `business_locations`, snapshots de coleta/entrega
em `delivery_requests`, e `proof_of_delivery`; índices GiST. Consulta de candidatos:
`ST_DWithin(driver_locations.position, pickup_point, raio_metros)`. Google Maps entra
**depois** só no subconjunto, para rota/ETA.

> **Schema `extensions` (Sessão 03.5):** o PostGIS vive no schema `extensions`, não em
> `public`. O runner de migrations/testes **não** inclui `extensions` no `search_path`
> padrão — toda migration e teste que use `geography`/`ST_*` deve declarar
> `set search_path to public, extensions;` no topo (sem isto: `ERROR 42704 type
> "geography" does not exist`). RPCs que não usam PostGIS usam
> `set search_path = public, pg_catalog`.

## Abstrações

```
GeocodingProvider
  - geocode(address) → coordenadas + validação
  - reverse(lat,lng) → endereço
  - validateAddress(address) → validação/normalização

RoutingProvider
  - route(origin, destination, { travelMode: CAR | TWO_WHEELER }) →
      { distance_meters, duration_seconds, polyline, legs }
  - eta(origin, destination, travelMode) → duração estimada
```

## Capacidades necessárias

- geocodificação;
- validação de endereço;
- coordenadas;
- distância de rota (real, não linha reta);
- duração estimada;
- rota de carro;
- rota `TWO_WHEELER`/motocicleta quando aplicável;
- cache quando seguro;
- tratamento de falhas.

## Cache

Cache de geocoding e routing quando seguro (endereços estáveis, rotas repetidas)
para controlar custo. TTL e invalidação definidos. Distância cobrada em corrida
**deve** usar rota real, não linha reta, quando o cálculo exigir.

## Tratamento de erros

- endereço não encontrado;
- endereço ambíguo (múltiplos matches → desambiguar ou rejeitar);
- GPS indisponível;
- coordenadas inválidas;
- perda de conexão.

## Localização do entregador

Modelo: latitude, longitude, accuracy, heading (quando disponível),
`captured_at` (device), `received_at` (server).

### Atualização

- **Não presumir** rastreamento confiável em background numa PWA.
- Durante corrida ativa **e PWA em foreground**: ~10s entre atualizações
  (configurável).
- Tracking persistente em background, se um dia necessário, **provavelmente exigirá
  app nativo**.

### Conceito de STALE

- Toda coordenada tem `location_timestamp`/`captured_at`.
- Coordenada antiga é **stale**.
- **Nenhuma decisão crítica** trata coordenada stale como atual.
- O dashboard deve indicar visualmente quando a posição é stale.

## Custo e limites

Documentar (na Sessão 20): fornecedor, custos potenciais por chamada, limites de
quota, estratégia de cache. Evitar chamadas desnecessárias.