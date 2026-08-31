import "server-only";
import type { WhatsAppProvider, WhatsAppSendInput, WhatsAppSendResult } from "./whatsapp-provider";

/**
 * Provider DataCrazy nativo (ADR-021 D1). Envia mensagem a uma **conversa existente**
 * (janela 24h aberta). **HARD CONSTRAINT**: sem endpoint p/ iniciar conversa com número
 * novo — `conversationId` é obrigatório. Cold proactive (OTP ao recebedor, driver fora
 * da janela) fica com Evolution.
 *
 * Endpoint: `POST {baseUrl}/api/v1/conversations/{conversationId}/messages`
 * Auth: `Authorization: Bearer {apiKey}` (outbound ≠ inbound: inbound é HMAC,
 * outbound é Bearer — mecanismos diferentes).
 * Body: `{body, isInternal:false}`. Response: `MessageDto.id` → `externalId`.
 *
 * Segredo (`apiKey`) nunca logado. Erros são sanitizados (só status HTTP, sem body p/
 * evitar vazar PII/conversationId em logs).
 */
export type DataCrazyConfig = {
  baseUrl: string; // DATACRAZY_API_BASE_URL
  apiKey: string;  // DATACRAZY_API_KEY
};

export function createDataCrazyProvider(config: DataCrazyConfig): WhatsAppProvider {
  return {
    async send(input: WhatsAppSendInput): Promise<WhatsAppSendResult> {
      if (!input.conversationId) {
        // DataCrazy não inicia conversas — sem conversationId não há como enviar.
        throw new Error("datacrazy_send_requires_conversation_id");
      }
      const base = config.baseUrl.replace(/\/+$/, "");
      const url = `${base}/api/v1/conversations/${input.conversationId}/messages`;
      const res = await fetch(url, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${config.apiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ body: input.body, isInternal: false }),
      });
      if (!res.ok) {
        // sanitizado: só status (body do provider pode conter PII).
        throw new Error(`datacrazy_send_failed: ${res.status}`);
      }
      const data = (await res.json().catch(() => ({}))) as { id?: string };
      return { ok: true, externalId: data.id, channel: "whatsapp", provider: "datacrazy" };
    },
  };
}