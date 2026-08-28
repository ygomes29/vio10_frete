# FRONTEND.md — Frontend do ViO10

## 1. Um codebase, três superfícies

Tudo em **Next.js 16.3.3 (App Router)**, num único projeto, organizado por
**route groups**:

- `/app/(driver)/...` — **PWA do entregador** (prioridade: uso rápido no celular).
- `/app/(admin)/...` — **Dashboard ViO10** (central operacional).
- `/app/(business)/...` — **Portal da empresa cliente**.

Stack de UI: TypeScript, Tailwind CSS, shadcn/ui.

## 2. Princípio inegociável

> **O frontend apresenta estado oficial e coleta ações. Nunca inventa estado.**

- Status de corrida, preço, ETA, entregador atribuído — tudo vem do backend.
- Nenhuma decisão financeira ou de estado é tomada no frontend.
- Regras de negócio **não** são duplicadas no frontend. Se a regra importa para
  consistência, ela vive no backend; o frontend só reflete.

## 3. PWA do entregador

Prioridade absoluta: **uso rápido no celular**. Botões grandes, mínimo de cliques,
excelente mobile, estados de loading/erro/sucesso, tolerância a conexão instável,
proteção contra clique duplicado.

Fluxos: login → disponível/indisponível → oportunidade atual → ACEITAR/RECUSAR/
FAZER LANCE → corrida atribuída → navegar até coleta → cheguei → produto coletado →
iniciar entrega → navegar até destino → concluir entrega → prova de entrega →
histórico básico → ganhos básicos.

### Localização do entregador

- Não presumir rastreamento confiável em background.
- Durante corrida ativa **e PWA em foreground**: atualização ~10s (configurável).
- Sempre há `location_timestamp`; coordenada antiga é **stale** e não pode ser
  tratada como atual em decisões críticas.
- Tracking persistente em background, se um dia necessário, provavelmente exigirá
  app nativo. Documentado em `docs/GEOLOCATION.md`.

## 4. Dashboard ViO10 (admin)

Central operacional: corridas por estado, entregadores disponíveis/ocupados/offline,
empresas, volume, valores, falhas. Tela de detalhe da corrida com **timeline de
`delivery_events`**. Ações administrativas só quando há regra de negócio
correspondente — **nada de editar status arbitrariamente**. Mapa operacional com
coleta/destino/entregador.

## 5. Portal da empresa

Solicitar corrida, obter cotação, confirmar, acompanhar, histórico, repetir
entrega, comprovante, cobranças, gerenciar usuários/unidades. WhatsApp continua
canal válido; o portal **não** é obrigatório para usar o ViO10. Isolamento total
entre empresas.

## 6. Convenções

- Consumo de estado via chamadas ao backend (Route Handlers/Server Actions
  originados no frontend) e, onde fizer sentido, **Supabase Realtime** para
  atualizações ao vivo (ex.: posição/status no dashboard).
- Componentes de UI em shadcn/ui; design tokens compartilhados entre as três
  superfícies.
- Tratamento de erro e loading em toda chamada; nunca assumir sucesso.
- Proteção contra cliques duplicados em ações mutantes (desabilitar botão até
  resposta; idempotência no backend é a garantia real, a UI é camada de UX).
- Sem chaves/secret de serviços externos no cliente. O frontend só lida com
  dados que o backend autoriza a expor.