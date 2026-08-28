-- 0025_state_machine_pod_prep.sql
-- Sessão 11 (ADR-016) — preparação de schema para a máquina de estados pós-assigned +
-- POD gate. SEM funções aqui (gotcha: ALTER TYPE ... ADD VALUE não é referenciável na
-- mesma transação — as RPCs que usam 'pod_submitted' vivem em 0026, transação separada).
--
-- Changes:
--   1. add enum value 'pod_submitted' to delivery_event_type.
--   2. unique (delivery_request_id, pod_type) em proof_of_delivery (1 POD por tipo/corrida).
-- Nenhuma tabela/coluna nova. Nenhum grant novo.

-- 1. Novo tipo de evento de auditoria para submissão de POD.
alter type public.delivery_event_type add value if not exists 'pod_submitted';

-- 2. Um POD por (corrida, tipo) — impede double-submit (capturado como pod_already_submitted
--    pela RPC submit_proof_of_delivery em 0026).
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'pod_request_type_uk' and conrelid = 'public.proof_of_delivery'::regclass
  ) then
    alter table public.proof_of_delivery
      add constraint pod_request_type_uk unique (delivery_request_id, pod_type);
  end if;
end $$;