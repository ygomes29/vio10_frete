# ADR-002 — Backend dentro do Next.js no MVP

- **Status**: Aprovado
- **Data**: 2026-08-27
- **Sessão**: 02

## Contexto

Precisamos de uma camada "backend decide" que expõe API para n8n/DataCrazy/frontend
e aplica regras de negócio e autorização. A lógica crítica de atomicidade já mora no
Postgres via RPCs.

## Decisão

No MVP, o backend vive **dentro do projeto Next.js 16.3.3**:

- **Route Handlers** para integrações externas (n8n, DataCrazy, webhooks).
- **Server Actions** somente para ações originadas no próprio frontend.
- **Camada de domínio/serviço** para regras de negócio.
- **RPC do Postgres** para operações que exigem atomicidade.

n8n e DataCrazy **não** dependem de Server Actions internas. Fronteiras:
`UI → application/service → domain → persistence/RPC`.

## Consequências

- Sem serviço Node separado no MVP → menos complexidade e sem schema drift.
- Se surgirem workers pesados/filas, extraímos um serviço dedicado depois.
- Regras de negócio não ficam em componentes React nem em Route Handlers.

## Referências

`BACKEND.md`, `ARCHITECTURE.md`, ADR-001.