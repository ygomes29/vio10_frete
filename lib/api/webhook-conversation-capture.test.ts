import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  extractConversationRef,
  captureConversationFromPayload,
} from "./webhook-conversation-capture";

beforeEach(() => {
  vi.restoreAllMocks();
});
afterEach(() => {
  vi.restoreAllMocks();
});

describe("extractConversationRef", () => {
  it("paths raiz from + conversation_id", () => {
    expect(extractConversationRef({ from: "+553191234", conversation_id: "conv-1" })).toEqual({
      phone: "553191234",
      conversationId: "conv-1",
    });
  });
  it("paths nested message.from + conversation.id", () => {
    expect(
      extractConversationRef({ message: { from: "559988877" }, conversation: { id: "c2" } }),
    ).toEqual({ phone: "559988877", conversationId: "c2" });
  });
  it("paths data.message.from + data.conversation.id", () => {
    expect(
      extractConversationRef({ data: { message: { from: "(31) 91234-5678" }, conversation: { id: "c3" } } }),
    ).toEqual({ phone: "31912345678", conversationId: "c3" });
  });
  it("sem phone → null", () => {
    expect(extractConversationRef({ conversation_id: "c" })).toBeNull();
  });
  it("sem conversation_id → null", () => {
    expect(extractConversationRef({ from: "55319" })).toBeNull();
  });
  it("phone c/ poucos dígitos → null", () => {
    expect(extractConversationRef({ from: "123", conversation_id: "c" })).toBeNull();
  });
});

describe("captureConversationFromPayload", () => {
  function makeClient() {
    const upserts: { row: Record<string, unknown>; opts: unknown }[] = [];
    const client = {
      from: () => {
        const chain = {
          upsert: (row: Record<string, unknown>, opts?: unknown) => { upserts.push({ row, opts }); return chain; },
        };
        return chain;
      },
    } as unknown as SupabaseClient;
    return { client, upserts };
  }

  it("upsert whatsapp_conversations c/ window 24h + provider datacrazy", async () => {
    const { client, upserts } = makeClient();
    await captureConversationFromPayload(
      client,
      { from: "553191234", conversation_id: "conv-1" },
      "corr-1",
    );
    expect(upserts).toHaveLength(1);
    const row = upserts[0].row;
    expect(row.phone).toBe("553191234");
    expect(row.conversation_id).toBe("conv-1");
    expect(row.provider).toBe("datacrazy");
    expect(row.last_inbound_at).toBeTruthy();
    // window_expires_at ~ now + 24h
    const win = new Date(row.window_expires_at as string).getTime();
    expect(win).toBeGreaterThan(Date.now() + 23 * 3600_000);
    expect((upserts[0].opts as { onConflict: string }).onConflict).toBe("phone");
  });

  it("sem ref → no-op (não upserta)", async () => {
    const { client, upserts } = makeClient();
    await captureConversationFromPayload(client, { foo: "bar" }, "c");
    expect(upserts).toHaveLength(0);
  });
});