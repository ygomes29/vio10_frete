-- 0002_enums.sql
-- Todos os enums do domínio. Espelhar no TypeScript.

do $$ begin
  -- Estados da corrida. `bidding` NÃO existe aqui (sub-fase de searching_driver).
  create type delivery_status as enum (
    'draft','quoted','searching_driver','assigned','driver_to_pickup',
    'at_pickup','picked_up','in_transit','delivered',
    'cancelled','failed','expired'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type driver_availability_status as enum (
    'offline','available','offered','busy','paused'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type vehicle_type as enum ('motorcycle','car');
exception when duplicate_object then null; end $$;

do $$ begin
  create type delivery_request_origin as enum (
    'dashboard','whatsapp','api','operator','integration'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type delivery_priority as enum ('standard','urgent');
exception when duplicate_object then null; end $$;

do $$ begin
  create type dispatch_round_status as enum ('open','closed','superseded','expired');
exception when duplicate_object then null; end $$;

do $$ begin
  -- pending = aguardando resposta; accepted/counter_bid/decline = respostas;
  -- won/lost = resultado da seleção; expired = oferta vencida sem resposta.
  create type delivery_offer_status as enum (
    'pending','accepted','counter_bid','declined','expired','won','lost'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type bid_response_type as enum ('accept','counter_bid','decline');
exception when duplicate_object then null; end $$;

do $$ begin
  create type assignment_status as enum ('active','superseded','revoked','completed');
exception when duplicate_object then null; end $$;

do $$ begin
  create type driver_account_status as enum ('pending','active','suspended','blocked');
exception when duplicate_object then null; end $$;

do $$ begin
  create type document_type as enum (
    'cnh','vehicle_registration','insurance','other'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type pod_type as enum ('pickup','delivery');
exception when duplicate_object then null; end $$;

do $$ begin
  create type quote_status as enum ('pending','confirmed','expired','superseded');
exception when duplicate_object then null; end $$;

do $$ begin
  create type platform_role as enum ('super_admin','admin','operator');
exception when duplicate_object then null; end $$;

do $$ begin
  create type org_role as enum ('business_owner','business_user');
exception when duplicate_object then null; end $$;

do $$ begin
  -- Timeline/auditoria da corrida. Eventos imutáveis (ver trigger em 0010).
  create type delivery_event_type as enum (
    'delivery_created','quote_created','quote_confirmed','dispatch_started',
    'round_opened','offer_created','offer_accepted','counter_bid_received',
    'offer_declined','round_closed','winner_selected','driver_assigned',
    'assignment_superseded','driver_to_pickup','arrived_at_pickup','picked_up',
    'in_transit','delivered','cancelled','failed','expired'
  );
exception when duplicate_object then null; end $$;