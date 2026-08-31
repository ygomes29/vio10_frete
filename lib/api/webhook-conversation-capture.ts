import "server-only";
import type { SupabaseClient } from "@supabase/supabase-js";
import { logEvent } from "./http";

/**
 * Captura de conversa WhatsApp inbound (ADR-021 D1). Cada inbound DataCrazy atualiza
 * `whatsapp_conversations` (phone, conversation_id, window_expires_at=now+24h) p/ o
 * roteamento híbrido outbound saber qual provider usar (fresco→DataCrazy, expirado→Evolution).
 *
 * **Ressalva**: os nomes exatos dos campos do payload inbound DataCrazy precisam ser
 * confirmados com uma chamada real / docs do provider. A extração é defensiva (tenta
 * vários paths comuns); se não achar phone+conversation_id, loga e segue (best-effort,
 * não derruba o roteamento do webhook). Confirmar live na Sessão 16 (Phase 2).
 */

export type ConversationRef = { phone: string; conversationId: string } | null;

/** Normaliza phone p/ E.164 sem '+' (só dígitos). */
function normalizePhone(raw: string): string | null {
  const digits = raw.replace(/[^\d]/g, "");
  return digits.length >= 8 ? digits : null;
}

function pickStr(obj: unknown, paths: string[]): string | null {
  if (!obj || typeof obj !== "object") return null;
  for (const path of paths) {
    let cur: unknown = obj;
    for (const seg of path.split(".")) {
      if (cur && typeof cur === "object" && seg in (cur as Record<string, unknown>)) {
        cur = (cur as Record<string, unknown>)[seg];
      } else {
        cur = undefined;
        break;
      }
    }
    if (typeof cur === "string" && cur.trim() !== "") return cur.trim();
  }
  return null;
}

/**
 * Extrai {phone, conversationId} do payload inbound DataCrazy. Puro (unit-testável).
 * Retorna null se não encontrar ambos.
 */
export function extractConversationRef(payload: Record<string, unknown>): ConversationRef {
  const phoneRaw = pickStr(payload, [
    "from",
    "phone",
    "message.from",
    "data.message.from",
    "contact.phone",
    "data.contact.phone",
    "sender.phone",
  ]);
  const convoRaw = pickStr(payload, [
    "conversation_id",
    "conversation.id",
    "data.conversation.id",
    "data.conversation_id",
    "message.conversation_id",
  ]);
  if (!phoneRaw || !convoRaw) return null;
  const phone = normalizePhone(phoneRaw);
  if (!phone) return null;
  return { phone, conversationId: convoRaw };
}

/** Upsert em whatsapp_conversations (window 24h renovada a cada inbound). */
export async function captureConversationFromPayload(
  client: SupabaseClient,
  payload: Record<string, unknown>,
  correlationId: string,
): Promise<void> {
  const ref = extractConversationRef(payload);
  if (!ref) {
    logEvent({ correlation_id: correlationId, event: "conversation.capture", ok: false, reason: "no_ref" });
    return;
  }
  const windowExpiresAt = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();
  const now = new Date().toISOString();
  await client.from("whatsapp_conversations").upsert(
    {
      phone: ref.phone,
      conversation_id: ref.conversationId,
      provider: "datacrazy",
      window_expires_at: windowExpiresAt,
      last_inbound_at: now,
      updated_at: now,
    },
    { onConflict: "phone", ignoreDuplicates: false },
  );
  logEvent({ correlation_id: correlationId, event: "conversation.capture", ok: true });
}