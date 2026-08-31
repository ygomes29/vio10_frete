import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { createDataCrazyProvider } from "./datacrazy-provider";
import { createEvolutionProvider } from "./evolution-provider";
import { createHybridWhatsAppProvider } from "./hybrid-whatsapp-provider";
import {
  registerWhatsAppProvider,
  resetWhatsAppProvider,
  getWhatsAppProvider,
  isWhatsAppAvailable,
  WhatsAppProviderNotConfiguredError,
  type WhatsAppProvider,
} from "./whatsapp-provider";

beforeEach(() => {
  resetWhatsAppProvider();
});
afterEach(() => {
  resetWhatsAppProvider();
  vi.restoreAllMocks();
});

describe("registry whatsapp-provider", () => {
  it("inicia sem provider (501 quando usado)", () => {
    expect(isWhatsAppAvailable()).toBe(false);
    expect(getWhatsAppProvider()).toBeNull();
  });
  it("register/available", () => {
    registerWhatsAppProvider({ send: async () => ({ ok: true, channel: "whatsapp", provider: "evolution" }) });
    expect(isWhatsAppAvailable()).toBe(true);
    expect(getWhatsAppProvider()).not.toBeNull();
  });
});

describe("datacrazy-provider", () => {
  it("exige conversationId (HARD CONSTRAINT)", async () => {
    const p = createDataCrazyProvider({ baseUrl: "https://dc.test", apiKey: "k" });
    await expect(p.send({ to: "55319", body: "oi" })).rejects.toThrow("datacrazy_send_requires_conversation_id");
  });
  it("POST conversations/{id}/messages Bearer + body {body,isInternal:false}", async () => {
    const fetchMock = vi.fn(async (_url: string, _init: RequestInit) => ({
      ok: true,
      json: async () => ({ id: "msg-1" }),
    }));
    vi.stubGlobal("fetch", fetchMock);
    const p = createDataCrazyProvider({ baseUrl: "https://dc.test/", apiKey: "secret" });
    const r = await p.send({ to: "55319", body: "oi", conversationId: "conv-9" });
    expect(r).toEqual({ ok: true, externalId: "msg-1", channel: "whatsapp", provider: "datacrazy" });
    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe("https://dc.test/api/v1/conversations/conv-9/messages");
    expect(init.method).toBe("POST");
    const headers = init.headers as Record<string, string>;
    expect(headers.Authorization).toBe("Bearer secret");
    expect(JSON.parse(init.body as string)).toEqual({ body: "oi", isInternal: false });
  });
  it("erro HTTP → datacrazy_send_failed:<status> (sem vazar body)", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => ({ ok: false, status: 401, text: async () => "leak" })));
    const p = createDataCrazyProvider({ baseUrl: "https://dc.test", apiKey: "k" });
    await expect(p.send({ to: "55319", body: "oi", conversationId: "c" })).rejects.toThrow("datacrazy_send_failed: 401");
  });
});

describe("evolution-provider", () => {
  it("POST sendText/{instance} header apikey + body nested", async () => {
    const fetchMock = vi.fn(async (_url: string, _init: RequestInit) => ({ ok: true, json: async () => ({ key: { id: "ev-1" } }) }));
    vi.stubGlobal("fetch", fetchMock);
    const p = createEvolutionProvider({ apiUrl: "http://evo.test/", apiKey: "k", instanceName: "vio10" });
    const r = await p.send({ to: "55319", body: "oi" });
    expect(r).toEqual({ ok: true, externalId: "ev-1", channel: "whatsapp", provider: "evolution" });
    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe("http://evo.test/message/sendText/vio10");
    const headers = init.headers as Record<string, string>;
    expect(headers.apikey).toBe("k");
    expect(JSON.parse(init.body as string)).toEqual({ number: "55319", textMessage: { text: "oi" } });
  });
  it("fallback flat em 400 (GitHub #2570)", async () => {
    const fetchMock = vi.fn(async (url: string, init: RequestInit) => {
      const body = JSON.parse(init.body as string);
      if ("textMessage" in body) return { ok: false, status: 400 };
      // flat
      expect(body).toEqual({ number: "55319", text: "oi" });
      return { ok: true, json: async () => ({ key: { id: "ev-flat" } }) };
    });
    vi.stubGlobal("fetch", fetchMock);
    const p = createEvolutionProvider({ apiUrl: "http://evo.test", apiKey: "k", instanceName: "vio10" });
    const r = await p.send({ to: "55319", body: "oi" });
    expect(r.externalId).toBe("ev-flat");
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });
  it("401 não tenta fallback → lança", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => ({ ok: false, status: 401 })));
    const p = createEvolutionProvider({ apiUrl: "http://evo.test", apiKey: "k", instanceName: "vio10" });
    await expect(p.send({ to: "55319", body: "oi" })).rejects.toThrow("evolution_send_failed: 401");
  });
});

describe("hybrid-whatsapp-provider (roteamento D1)", () => {
  const dc: WhatsAppProvider = { send: vi.fn(async (_i) => ({ ok: true, externalId: "dc-msg", channel: "whatsapp" as const, provider: "datacrazy" as const })) };
  const evo: WhatsAppProvider = { send: vi.fn(async (_i) => ({ ok: true, externalId: "evo-msg", channel: "whatsapp" as const, provider: "evolution" as const })) };

  it("conversa fresca → DataCrazy (usa conversation_id)", async () => {
    const resolve = vi.fn(async () => ({ conversationId: "conv-1", windowExpiresAt: new Date(Date.now() + 3600_000).toISOString() }));
    const h = createHybridWhatsAppProvider({ datacrazy: dc, evolution: evo, resolveConversation: resolve });
    const r = await h.send({ to: "55319", body: "x" });
    expect(r.provider).toBe("datacrazy");
    expect(resolve).toHaveBeenCalledWith("55319");
    expect((dc.send as ReturnType<typeof vi.fn>).mock.calls[0][0].conversationId).toBe("conv-1");
  });
  it("conversa expirada → Evolution (cold)", async () => {
    const resolve = vi.fn(async () => ({ conversationId: "conv-1", windowExpiresAt: new Date(Date.now() - 1000).toISOString() }));
    const h = createHybridWhatsAppProvider({ datacrazy: dc, evolution: evo, resolveConversation: resolve });
    const r = await h.send({ to: "55319", body: "x" });
    expect(r.provider).toBe("evolution");
    expect((evo.send as ReturnType<typeof vi.fn>).mock.calls[0][0].conversationId).toBeNull();
  });
  it("sem conversa (null) → Evolution", async () => {
    const h = createHybridWhatsAppProvider({ datacrazy: dc, evolution: evo, resolveConversation: async () => null });
    const r = await h.send({ to: "55319", body: "x" });
    expect(r.provider).toBe("evolution");
  });
  it("conversationId explícito → DataCrazy (caller forçou)", async () => {
    const resolve = vi.fn(async () => null);
    const h = createHybridWhatsAppProvider({ datacrazy: dc, evolution: evo, resolveConversation: resolve });
    const r = await h.send({ to: "55319", body: "x", conversationId: "forced" });
    expect(r.provider).toBe("datacrazy");
    expect(resolve).not.toHaveBeenCalled();
  });
  it("fresco mas só Evolution configurado → Evolution (fallback)", async () => {
    const resolve = vi.fn(async () => ({ conversationId: "c", windowExpiresAt: new Date(Date.now() + 3600_000).toISOString() }));
    const h = createHybridWhatsAppProvider({ evolution: evo, resolveConversation: resolve });
    const r = await h.send({ to: "55319", body: "x" });
    expect(r.provider).toBe("evolution");
  });
  it("nenhum provider → WhatsAppProviderNotConfiguredError (501)", async () => {
    const h = createHybridWhatsAppProvider({ resolveConversation: async () => null });
    await expect(h.send({ to: "55319", body: "x" })).rejects.toBeInstanceOf(WhatsAppProviderNotConfiguredError);
  });
  it("conversationId explícito sem DataCrazy → 501", async () => {
    const h = createHybridWhatsAppProvider({ evolution: evo, resolveConversation: async () => null });
    await expect(h.send({ to: "55319", body: "x", conversationId: "c" })).rejects.toBeInstanceOf(WhatsAppProviderNotConfiguredError);
  });
});