-- 0029_whatsapp_conversations.sql
-- Sessão 16 (ADR-021) — preparação de schema para WhatsApp outbound híbrido (D1).
-- Captura `conversation_id` + janela 24h de cada inbound DataCrazy p/ o roteamento
-- DataCrazy-vs-Evolution decidir no outbound (conversa fresca → DataCrazy nativo;
-- expirada/inexistente → Evolution API V2 cold proactive).
--
-- SEM funções (schema prep puro, mesmo padrão de split 0025/0027). Writes só via
-- backend (service_role, system-client) — nenhuma policy DML p/ authenticated
-- (default-deny). authenticated/anon não leem (PII: phone + conversation_id).
--
-- Changes:
--   1. create table whatsapp_conversations (phone, conversation_id, provider,
--      window_expires_at, last_inbound_at, updated_at); unique (phone).
--   2. RLS enable + default-deny (nenhuma policy).
--   3. grants: service_role all; revoke authenticated/anon.
--   4. notifications: add recipient_phone + relax do CHECK de "ao menos um destinatário"
--      p/ aceitar destinatários externos (OTP ao recebedor = delivery_contact_phone,
--      que não é user/driver cadastrado). service_role já tem DML full (0015:33);
--      authenticated mantém SELECT sob RLS (policy notif_sel não referencia a coluna).

-- 1. Tabela de conversas WhatsApp por telefone (normaliza 1 linha por número).
--    phone: E.164 sem '+' (ex.: '55319...'); conversation_id: id da conversa no provider
--    (DataCrazy MessageDto.conversation.id); window_expires_at: now()+24h a cada inbound
--    (janela de serviço Meta — free-form dentro, template fora); provider: quem abriu
--    ('datacrazy'|'evolution'); last_inbound_at: último inbound recebido.
create table if not exists public.whatsapp_conversations (
  id                uuid primary key default gen_random_uuid(),
  phone             text not null,                       -- E.164 sem '+', normalizado
  conversation_id   text,                                -- id da conversa no provider
  provider          text not null default 'datacrazy',  -- 'datacrazy' | 'evolution'
  window_expires_at timestamptz,                         -- now() + 24h a cada inbound
  last_inbound_at   timestamptz,                         -- último inbound recebido
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint whatsapp_conversations_phone_uk unique (phone)
);
create index if not exists idx_whatsapp_conversations_window
  on public.whatsapp_conversations(window_expires_at);

-- 2. RLS default-deny: nenhuma policy. Leituras/escritas só via service_role (backend,
--    bypass de RLS) — phone + conversation_id são PII, nunca expostos a authenticated/anon.
alter table public.whatsapp_conversations enable row level security;
-- intencionalmente sem policies (default-deny p/ authenticated/anon).

-- 3. Grants: service_role tudo (system-scoped, bypassa RLS); authenticated/anon nada.
grant all on public.whatsapp_conversations to service_role;
revoke all on public.whatsapp_conversations from authenticated;
revoke all on public.whatsapp_conversations from anon;

comment on table public.whatsapp_conversations is
  'ViO10: conversas WhatsApp por telefone (Sessão 16 / 0029, ADR-021 D1). Captura conversation_id + janela 24h de cada inbound DataCrazy p/ roteamento híbrido outbound (fresco→DataCrazy, expirado→Evolution). RLS default-deny; writes só via backend service_role. PII (phone).';

-- 4. notifications: destinatário externo (recebedor/contato de coleta) via phone.
--    O CHECK original (0011) exigia recipient_user_id OR recipient_driver_id, mas o OTP
--    e status-update ao recebedor usam delivery_contact_phone (externo, sem user/driver).
--    Adiciona recipient_phone e relaxa o check. Sem alterar grants (service_role DML full
--    em 0015:33; authenticated SELECT sob RLS 0017 — policy notif_sel não referencia a coluna;
--    linhas phone-only têm user/driver null → só admin lê, default-deny p/ demais).
alter table public.notifications add column if not exists recipient_phone text;

alter table public.notifications drop constraint if exists notifications_at_least_one_recipient_chk;
alter table public.notifications
  add constraint notifications_at_least_one_recipient_chk
  check (recipient_user_id is not null or recipient_driver_id is not null or recipient_phone is not null);

comment on column public.notifications.recipient_phone is
  'Destinatário externo (não user/driver) — ex.: recebedor da entrega (delivery_contact_phone). Sessão 16 / 0029.';