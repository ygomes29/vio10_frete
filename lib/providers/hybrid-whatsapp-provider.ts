import "server-only";
import type { WhatsAppProvider, WhatsAppSendInput, WhatsAppSendResult } from "./whatsapp-provider";
import { WhatsAppProviderNotConfiguredError } from "./whatsapp-provider";

/**
 * Provider híbrido (ADR-021 D1). Encapsula DataCrazy + Evolution + a consulta a
 * `whatsapp_conversations` para decidir o roteamento. O `resolveConversation` é
 * injetado (decisão de DB fica fora do provider p/ testabilidade — o registration
 * injeta uma fn que usa o system-client).
 *
 * Roteamento:
 *  1. `input.conversationId` explícito → DataCrazy (caller já validou a janela).
 *     Sem DataCrazy configurado → 501.
 *  2. Senão, resolve a conversa do phone:
 *     - fresca (`window_expires_at > now()`) + DataCrazy presente → DataCrazy.
 *     - senão + Evolution presente → Evolution (cold proactive).
 *     - senão + DataCrazy presente (stale) → DataCrazy (tenta; Meta pode rejeitar
 *       free-form fora da janela — o erro do provider sobe).
 *     - nenhum provider → 501.
 *
 * PII: `phone` é PII; o provider não loga phone/conversationId (só correlation no service).
 */
export type ConversationInfo = { conversationId: string; windowExpiresAt: string } | null;
export type ResolveConversation = (phone: string) => Promise<ConversationInfo>;

export type HybridWhatsAppConfig = {
  datacrazy?: WhatsAppProvider;
  evolution?: WhatsAppProvider;
  resolveConversation: ResolveConversation;
};

export function createHybridWhatsAppProvider(config: HybridWhatsAppConfig): WhatsAppProvider {
  return {
    async send(input: WhatsAppSendInput): Promise<WhatsAppSendResult> {
      // 1. Caller forçou conversationId → DataCrazy.
      if (input.conversationId) {
        if (!config.datacrazy) throw new WhatsAppProviderNotConfiguredError();
        return config.datacrazy.send(input);
      }
      // 2. Resolve conversa do phone.
      const convo = await config.resolveConversation(input.to);
      const fresh =
        convo &&
        convo.conversationId &&
        new Date(convo.windowExpiresAt).getTime() > Date.now();
      if (fresh && config.datacrazy) {
        return config.datacrazy.send({ ...input, conversationId: convo!.conversationId });
      }
      if (config.evolution) {
        return config.evolution.send({ ...input, conversationId: null });
      }
      // 3. Stale mas DataCrazy presente → tenta (pode falhar fora da janela).
      if (convo?.conversationId && config.datacrazy) {
        return config.datacrazy.send({ ...input, conversationId: convo.conversationId });
      }
      throw new WhatsAppProviderNotConfiguredError();
    },
  };
}