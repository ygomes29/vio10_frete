import "server-only";
import {
  registerWhatsAppProvider,
  getWhatsAppProvider,
} from "./whatsapp-provider";
import { createDataCrazyProvider } from "./datacrazy-provider";
import { createEvolutionProvider } from "./evolution-provider";
import { createHybridWhatsAppProvider } from "./hybrid-whatsapp-provider";
import { createSystemClient } from "@/lib/supabase/system-client";

/**
 * Registro do provider WhatsApp a partir de env (ADR-021 D1/D2). Idempotente:
 * se já há provider registrado (env wired OU teste injetou mock), no-op. Se nenhum
 * env de WhatsApp configurado, registra nada → `sendNotification` lança 501 ao usar.
 *
 * **service_role** fica no backend (system-client) — nunca vaza ao n8n/IA/DataCrazy.
 * n8n não chama este módulo; chama o Route Handler (`x-internal-api-key`).
 */
export function ensureWhatsAppProviderRegistered(): void {
  if (getWhatsAppProvider()) return; // já registrado (env ou teste)

  const datacrazyKey = process.env.DATACRAZY_API_KEY;
  const datacrazyBase = process.env.DATACRAZY_API_BASE_URL;
  const evoUrl = process.env.EVOLUTION_API_URL;
  const evoKey = process.env.EVOLUTION_API_KEY;
  const evoInstance = process.env.EVOLUTION_INSTANCE_NAME;

  const datacrazy =
    datacrazyKey && datacrazyBase
      ? createDataCrazyProvider({ apiKey: datacrazyKey, baseUrl: datacrazyBase })
      : undefined;
  const evolution =
    evoUrl && evoKey && evoInstance
      ? createEvolutionProvider({ apiUrl: evoUrl, apiKey: evoKey, instanceName: evoInstance })
      : undefined;

  if (!datacrazy && !evolution) return; // 501 quando usado (ProviderNotConfigured)

  registerWhatsAppProvider(
    createHybridWhatsAppProvider({
      datacrazy,
      evolution,
      resolveConversation: async (phone) => {
        const client = createSystemClient();
        const res = await client
          .from("whatsapp_conversations")
          .select("conversation_id, window_expires_at")
          .eq("phone", phone)
          .maybeSingle();
        // row-type `never` (sem Database generado) → cast explícito (padrão webhook-handler).
        const data = res.data as { conversation_id: string; window_expires_at: string } | null;
        if (!data) return null;
        return {
          conversationId: data.conversation_id,
          windowExpiresAt: data.window_expires_at,
        };
      },
    }),
  );
}