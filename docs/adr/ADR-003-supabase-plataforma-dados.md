# ADR-003 — Supabase como plataforma de dados/auth/storage

- **Status**: Aprovado
- **Data**: 2026-08-27
- **Sessão**: 02

## Contexto

Precisamos de PostgreSQL gerenciado, autenticação, storage de arquivos (prova de
entrega), isolamento multiempresa (RLS) e atualizações ao vivo (dashboard).

## Decisão

Adotar **Supabase** como:

- **PostgreSQL** — banco/fonte da verdade;
- **Auth** — sessão server-side/cookie-based (suporte oficial a Next.js App Router);
- **Storage** — prova de entrega com policies privadas;
- **RLS** — isolamento multiempresa (defense em profundidade);
- **Realtime** — quando fizer sentido (posição/status no dashboard).

## Consequências

- RLS é defesa em profundidade; a camada de serviço também autoriza.
- Storage privado por padrão; URLs assinadas/efêmeras.
- Realtime usado com critério, não como padrão para tudo.

## Referências

`ARCHITECTURE.md`, `docs/SECURITY.md`.
Fonte: [Supabase + Next.js](https://supabase.com/docs/guides/getting-started/quickstarts/nextjs).