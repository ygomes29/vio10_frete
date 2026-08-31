import "server-only";
import type { WhatsAppProvider, WhatsAppSendInput, WhatsAppSendResult } from "./whatsapp-provider";

/**
 * Provider Evolution API V2 (ADR-021 D1). Cold proactive: envia a **qualquer número**,
 * sem conversa prévia (sidesteps a janela 24h/templates Meta — texto livre, não-oficial).
 * Cobrem OTP ao recebedor e ofertas a driver fora da janela DataCrazy.
 *
 * Endpoint: `POST {apiUrl}/message/sendText/{instanceName}`
 * Auth: header `apikey: {apiKey}` (não Bearer).
 * Body (v2.3.7): `{"number":"55319...", "textMessage":{"text":"..."}}`.
 *   Fallback (GitHub issue #2570): algumas instâncias rejeitam o shape nested e exigem
 *   flat `{"number","text"}` — tentamos nested primeiro; em 400/422 tentamos flat.
 * Response: `key.id` → `externalId`.
 *
 * Segredo (`apiKey`) nunca logado. Erros sanitizados (só status HTTP).
 */
export type EvolutionConfig = {
  apiUrl: string;       // EVOLUTION_API_URL
  apiKey: string;        // EVOLUTION_API_KEY
  instanceName: string;  // EVOLUTION_INSTANCE_NAME
};

export function createEvolutionProvider(config: EvolutionConfig): WhatsAppProvider {
  return {
    async send(input: WhatsAppSendInput): Promise<WhatsAppSendResult> {
      const base = config.apiUrl.replace(/\/+$/, "");
      const url = `${base}/message/sendText/${config.instanceName}`;
      const headers = {
        apikey: config.apiKey,
        "Content-Type": "application/json",
      };
      // Shapes em ordem de preferência (v2.3.7 nested → flat fallback #2570).
      const payloads: unknown[] = [
        { number: input.to, textMessage: { text: input.body } },
        { number: input.to, text: input.body },
      ];
      let lastErr = "evolution_send_failed";
      for (const payload of payloads) {
        const res = await fetch(url, {
          method: "POST",
          headers,
          body: JSON.stringify(payload),
        });
        if (res.ok) {
          const data = (await res.json().catch(() => ({}))) as { key?: { id?: string } };
          return { ok: true, externalId: data.key?.id, channel: "whatsapp", provider: "evolution" };
        }
        // 400/422 → provavelmente shape rejeitado; tenta próximo. 401/5xx → falha real.
        if (res.status === 400 || res.status === 422) {
          lastErr = `evolution_send_failed: ${res.status}`;
          continue;
        }
        throw new Error(`evolution_send_failed: ${res.status}`);
      }
      throw new Error(lastErr);
    },
  };
}