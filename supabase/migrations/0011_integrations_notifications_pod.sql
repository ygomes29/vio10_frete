-- 0011_integrations_notifications_pod.sql
-- Idempotência/integrações, notificações e proof of delivery.
set search_path to public, extensions;

-- webhook_events: dedup de webhooks inbound. (source, external_id) UNIQUE.
create table if not exists public.webhook_events (
  id              uuid primary key default gen_random_uuid(),
  source          text not null,            -- ex.: 'datacrazy', 'n8n', 'payment_gateway'
  external_id     text not null,            -- id do emissor
  event_type      text,
  payload         jsonb not null default '{}'::jsonb,
  signature_valid boolean not null default false,
  status          text not null default 'pending',  -- pending/processed/failed
  received_at     timestamptz not null default now(),
  processed_at    timestamptz,
  constraint webhook_events_source_external_uk unique (source, external_id)
);
create index if not exists idx_webhook_events_status
  on public.webhook_events(status) where status = 'pending';

-- integration_events: ledger de idempotência das operações (in/out).
create table if not exists public.integration_events (
  id                uuid primary key default gen_random_uuid(),
  source            text not null,
  idempotency_key   text,
  external_event_id text,
  event_type        text not null,
  payload           jsonb not null default '{}'::jsonb,
  result            jsonb,
  status            text not null default 'pending',
  created_at        timestamptz not null default now(),
  processed_at      timestamptz,
  constraint integration_events_source_idem_uk   unique (source, idempotency_key),
  constraint integration_events_source_ext_uk    unique (source, external_event_id)
);
create index if not exists idx_integration_events_type
  on public.integration_events(event_type) where status = 'pending';

-- notifications: registro de notificações (DataCrazy implementado em sessão futura).
create table if not exists public.notifications (
  id                uuid primary key default gen_random_uuid(),
  recipient_user_id uuid references public.profiles(id) on delete cascade,
  recipient_driver_id uuid references public.drivers(id) on delete cascade,
  channel           text not null,            -- whatsapp/push/email/sms
  event_type        text not null,
  template          text,
  provider          text,
  external_id       text,
  status            text not null default 'pending',  -- pending/sent/delivered/failed
  idempotency_key   text,
  attempts          integer not null default 0 check (attempts >= 0),
  payload           jsonb not null default '{}'::jsonb,
  created_at        timestamptz not null default now(),
  sent_at          timestamptz,
  constraint notifications_at_least_one_recipient_chk
    check (recipient_user_id is not null or recipient_driver_id is not null),
  constraint notifications_channel_external_uk unique (channel, external_id),
  constraint notifications_idempotency_uk unique (idempotency_key)
);

-- proof_of_delivery: coleta e entrega. Regra operacional (obrigatórios) vem em sessão futura.
create table if not exists public.proof_of_delivery (
  id                  uuid primary key default gen_random_uuid(),
  delivery_request_id uuid not null references public.delivery_requests(id) on delete restrict,
  pod_type            pod_type not null,             -- pickup/delivery
  storage_path        text,                          -- foto (Supabase Storage)
  otp_code            text,                          -- OTP quando utilizado
  receiver_name       text,
  location_point      geography(Point, 4326),
  notes               text,
  captured_at         timestamptz not null default now(),
  created_at          timestamptz not null default now()
);
create index if not exists idx_pod_request on public.proof_of_delivery(delivery_request_id);
create index if not exists idx_pod_point   on public.proof_of_delivery using gist (location_point);