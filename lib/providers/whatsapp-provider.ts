import "server-only";

/**
 * Abstração de provider de WhatsApp outbound (ADR-021 D1). Mesmo padrão do geo
 * (ADR-005): registry + `ProviderNotConfiguredError` (501 quando nenhum provider
 * registrado). A implementação concreta (híbrido DataCrazy + Evolution) é registrada
 * por `whatsapp-registration.ts` a partir de env (server-only, `service_role` interno).
 *
 * Trust boundary do WhatsApp outbound (ADR-021 D2): o **backend** envia e loga em
 * `notifications`. n8n/IA/DataCrazy **não** enviam direto — chamam o Route Handler
 * `POST /api/internal/notifications/send`. Segredos (API keys) ficam no backend.
 *
 * Semântica do roteamento híbrido (D1):
 *  - Conversa **fresca** (`window_expires_at > now()`) + `conversation_id` → DataCrazy
 *    nativo (`POST /conversations/{id}/messages`) — free-form dentro da janela 24h.
 *  - Sem conversa fresca (cold/expirada) → Evolution API V2 (`/message/sendText/{instance}`)
 *    — sidesteps templates Meta, envia p/ qualquer número.
 *  - Nenhum provider configurado → `WhatsAppProviderNotConfiguredError` (501).
 *
 * DataCrazy **não** tem endpoint p/ iniciar conversa com número novo (HARD CONSTRAINT);
 * Evolution cobre o cold proactive (OTP ao recebedor, driver fora da janela).
 */

export type WhatsAppSendInput = {
  /** E.164 sem '+' (ex.: '55319...'). Normalizado pelo caller. */
  to: string;
  /** Texto puro. Signed links vão como URL em texto puro (WhatsApp auto-detecta). */
  body: string;
  /**
   * Id da conversa no provider (DataCrazy). Quando presente, o roteador usa DataCrazy
   * (assume janela fresca — o caller/service já validou `window_expires_at > now()`).
   * Ausente → roteador usa Evolution (cold proactive).
   */
  conversationId?: string | null;
};

export type WhatsAppSendResult = {
  ok: boolean;
  /** Id da mensagem no provider → `notifications.external_id`. */
  externalId?: string;
  channel: "whatsapp";
  provider: "datacrazy" | "evolution";
};

export interface WhatsAppProvider {
  send(input: WhatsAppSendInput): Promise<WhatsAppSendResult>;
}

export class WhatsAppProviderNotConfiguredError extends Error {
  reason = "whatsapp_provider_not_configured";
  status = 501;
}

let registered: WhatsAppProvider | null = null;

export function registerWhatsAppProvider(provider: WhatsAppProvider): void {
  registered = provider;
}

export function getWhatsAppProvider(): WhatsAppProvider | null {
  return registered;
}

export function isWhatsAppAvailable(): boolean {
  return registered !== null;
}

/** Reset p/ testes (server-only; nunca exposto ao client/n8n). */
export function resetWhatsAppProvider(): void {
  registered = null;
}