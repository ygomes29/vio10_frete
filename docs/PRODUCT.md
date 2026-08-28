# docs/PRODUCT.md — Produto ViO10

## O que é

ViO10 é uma **plataforma de logística local e fretes rápidos**. Motor inteligente
de despacho e contratação de fretes locais. **Não é delivery de alimentos.**

## Escopo MVP

Operar em **Congonhas/MG**, conectando estabelecimentos comerciais locais a
entregadores (prioritariamente motociclistas) para entregas rápidas de produtos.

## Fluxo macro

1. Empresa solicita uma entrega (Portal ou WhatsApp).
2. Sistema entende origem, destino, produto, urgência e veículo necessário.
3. Sistema calcula faixa de preço (motor determinístico).
4. Sistema localiza entregadores elegíveis.
5. Oportunidade de corrida é oferecida (rodada de dispatch).
6. Entregadores podem ACEITAR (lance igual ao ofertado) ou FAZER LANCE
   (contraproposta) ou RECUSAR.
7. Sistema avalia candidatos (scoring determinístico).
8. Rodada fecha → um candidato é escolhido → atribuição **atômica**.
9. Sistema acompanha coleta e entrega.
10. Corrida concluída e registrada (com prova de entrega).

## Usuários / papéis

- **super_admin** — controle total da plataforma.
- **admin** — administração operacional do ViO10.
- **operator** — operação no dashboard.
- **business_owner** — dono da empresa cliente.
- **business_user** — usuário da empresa cliente.
- **driver** — entregador.

Detalhes de permissão em `docs/SECURITY.md`.

## Tenancy

`organization` (tenant / conta contratante, limite de RLS) → `business`
(negócio/marca) → `business_location` (unidade física). MVP normalmente 1:1:1;
arquitetura suporta multi-unidade sem reconstrução.

## Canais

- **Portal empresa** (web) — solicitar, cotar, confirmar, acompanhar.
- **WhatsApp via DataCrazy** — canal conversacional; não obrigatório usar o portal.
- **PWA do entregador** — execução da corrida.
- **Dashboard ViO10** — operação e monitoramento.

## MVP funcional

1. Cadastrar empresas. 2. Cadastrar entregadores. 3. Criar solicitação de entrega.
4. Calcular cotação. 5. Buscar entregadores. 6. Abrir oportunidade. 7. Receber
aceitações/lances. 8. Selecionar entregador. 9. Atribuir corrida (atômico).
10. Atualizar etapas de coleta/entrega. 11. Registrar prova de entrega.
12. Concluir corrida. 13. Visualizar operação. 14. Comunicar empresas e entregadores.

## Limites explícitos do MVP

- Sem surge pricing complexo.
- Scoring só com dados disponíveis (valor, ETA, distância).
- Sem rating/completion-rate como fator real até haver histórico.
- Multiempresa/multicidade: preparado, não construído.
- Financeiro: desenhar o modelo antes de implementar (Sessão 21).