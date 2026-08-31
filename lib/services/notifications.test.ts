import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  sendNotification,
  validateSendNotificationBody,
} from "./notifications";
import {
  registerWhatsAppProvider,
  resetWhatsAppProvider,
  WhatsAppProviderNotConfiguredError,
  type WhatsAppProvider,
  type WhatsAppSendInput,
} from "@/lib/providers/whatsapp-provider";

// Mocka generateOtp (deliveries) — OTP plaintext controlado, sem tocar RPC.
const generateOtpMock = vi.fn();
vi.mock("./deliveries", () => ({ generateOtp: (...args: unknown[]) => generateOtpMock(...args) }));

// Mocka createActionLink — token determinístico, sem depender de env secret.
vi.mock("@/lib/auth/signed-link", () => ({
  createActionLink: () => ({ token: "tok-mock", expiresAt: "2099-01-01T00:00:00.000Z" }),
  DEFAULT_ACTION_LINK_TTL: 900,
}));

// ensureWhatsAppProviderRegistered não precisa de mock: registramos um provider fake
// antes de cada teste → ele vê provider já registrado e é no-op (não lê env).

beforeEach(() => {
  resetWhatsAppProvider();
  generateOtpMock.mockReset();
});
afterEach(() => {
  resetWhatsAppProvider();
  vi.restoreAllMocks();
});

// ---- Mock client Supabase ----
type Eq = { col: string; val: unknown };
function makeClient(handlers: Record<string, (eqs: Eq[]) => unknown | null>) {
  const upserts: { table: string; row: Record<string, unknown>; opts: unknown }[] = [];
  const client = {
    from: (table: string) => {
      const eqs: Eq[] = [];
      const chain = {
        select: () => chain,
        eq: (col: string, val: unknown) => { eqs.push({ col, val }); return chain; },
        in: () => chain,
        upsert: (row: Record<string, unknown>, opts?: unknown) => { upserts.push({ table, row, opts }); return chain; },
        maybeSingle: async () => ({ data: handlers[table]?.(eqs) ?? null, error: null }),
      };
      return chain;
    },
  } as unknown as SupabaseClient;
  return { client, upserts };
}

const fakeProvider = (send: ReturnType<typeof vi.fn>): WhatsAppProvider =>
  ({ send }) as unknown as WhatsAppProvider;

// Mock tipado de provider.send — `mock.calls[0][0]` vira WhatsAppSendInput.
const mkSend = (externalId: string, provider: "evolution" | "datacrazy") =>
  vi.fn(async (_input: WhatsAppSendInput) => ({
    ok: true,
    externalId,
    channel: "whatsapp" as const,
    provider: provider as "evolution" | "datacrazy",
  }));

describe("validateSendNotificationBody", () => {
  it("aceita offer c/ offer_id", () => {
    expect(validateSendNotificationBody({ type: "offer", offer_id: "o1" })).toEqual({ valid: true });
  });
  it("aceita otp c/ delivery_id", () => {
    expect(validateSendNotificationBody({ type: "otp", delivery_id: "d1" })).toEqual({ valid: true });
  });
  it("rejeita offer sem offer_id", () => {
    expect(validateSendNotificationBody({ type: "offer" })).toEqual({ valid: false, reason: "invalid_param" });
  });
  it("rejeita otp sem delivery_id", () => {
    expect(validateSendNotificationBody({ type: "otp" })).toEqual({ valid: false, reason: "invalid_param" });
  });
  it("rejeita type inválido", () => {
    expect(validateSendNotificationBody({ type: "x", delivery_id: "d" })).toEqual({ valid: false, reason: "invalid_param" });
  });
  it("rejeita não-objeto", () => {
    expect(validateSendNotificationBody(null)).toEqual({ valid: false, reason: "invalid_param" });
  });
});

describe("sendNotification — offer (sem PII do cliente)", () => {
  it("envia ao driver, gera signed link, sem PII, loga notifications c/ idempotency_key", async () => {
    const send = mkSend("msg-x", "evolution");
    registerWhatsAppProvider(fakeProvider(send));
    process.env.NEXT_PUBLIC_APP_URL = "https://vio10.test";

    const { client, upserts } = makeClient({
      delivery_offers: () => ({ driver_id: "d1", driver_offer_cents: 1090, delivery_request_id: "del1", expires_at: new Date(Date.now() + 600_000).toISOString() }),
      drivers: () => ({ phone: "55319" }),
      delivery_requests: () => ({ vehicle_required: "motorcycle", priority: "standard" }),
    });

    const r = await sendNotification(client, { type: "offer", offer_id: "of1" }, "corr-1");

    expect(r.ok).toBe(true);
    expect(r).not.toHaveProperty("otp_code");
    // enviado ao driver phone
    expect(send.mock.calls[0][0].to).toBe("55319");
    const body: string = send.mock.calls[0][0].body;
    // signed link URL presente
    expect(body).toContain("https://vio10.test/api/offers/of1/respond?token=tok-mock");
    // valor formatado
    expect(body).toContain("R$ 10,90");
    // SEM PII do cliente (sem endereços/contatos)
    expect(body).not.toMatch(/rua|av\.|endereç/i);
    // notifications log
    const n = upserts.find((u) => u.table === "notifications");
    expect(n).toBeDefined();
    expect(n!.row.recipient_driver_id).toBe("d1");
    expect(n!.row.event_type).toBe("offer");
    expect(n!.row.idempotency_key).toBe("notif:offer:of1");
    expect(n!.row.provider).toBe("evolution");
    expect((n!.opts as { onConflict: string }).onConflict).toBe("idempotency_key");

    delete process.env.NEXT_PUBLIC_APP_URL;
  });

  it("offer inexistente → not_found (422)", async () => {
    registerWhatsAppProvider(fakeProvider(vi.fn()));
    const { client } = makeClient({ delivery_offers: () => null });
    const r = await sendNotification(client, { type: "offer", offer_id: "x" }, "c");
    expect(r).toEqual({ ok: false, reason: "not_found" });
  });
});

describe("sendNotification — otp (plaintext nunca sai do backend)", () => {
  it("gera OTP, envia ao recebedor, response E payload SEM otp_code", async () => {
    generateOtpMock.mockResolvedValue({ ok: true, reason: null, otp_code: "123456" });
    const send = mkSend("otp-msg", "evolution");
    registerWhatsAppProvider(fakeProvider(send));

    const { client, upserts } = makeClient({
      delivery_requests: () => ({
        id: "del1", status: "in_transit", vehicle_required: "motorcycle",
        pickup_address: "Rua Pickup", pickup_contact_name: null, pickup_contact_phone: "55888",
        delivery_address: "Rua Entrega", delivery_contact_name: "João", delivery_contact_phone: "55999",
      }),
    });

    const r = await sendNotification(client, { type: "otp", delivery_id: "del1" }, "corr-otp");

    // enviado ao recebedor c/ o código no corpo
    expect(send.mock.calls[0][0].to).toBe("55999");
    expect(send.mock.calls[0][0].body).toContain("123456");
    // response NÃO contém otp_code
    expect(r.ok).toBe(true);
    expect(JSON.stringify(r)).not.toContain("123456");
    // notifications.payload NÃO contém otp_code
    const n = upserts.find((u) => u.table === "notifications");
    expect(n).toBeDefined();
    expect(n!.row.recipient_phone).toBe("55999");
    expect(n!.row.event_type).toBe("otp");
    expect(n!.row.idempotency_key).toBe("notif:otp:del1");
    expect(JSON.stringify(n!.row.payload)).not.toContain("123456");
  });

  it("generate_delivery_otp falha → retorna reason (não envia)", async () => {
    generateOtpMock.mockResolvedValue({ ok: false, reason: "otp_not_generated" });
    const send = vi.fn();
    registerWhatsAppProvider(fakeProvider(send));
    const { client } = makeClient({});
    const r = await sendNotification(client, { type: "otp", delivery_id: "del1" }, "c");
    expect(r).toEqual({ ok: false, reason: "otp_not_generated" });
    expect(send).not.toHaveBeenCalled();
  });
});

describe("sendNotification — assignment (PII liberada pós-atribuição)", () => {
  it("envia PII (endereços/contatos) ao driver atribuído", async () => {
    const send = mkSend("a", "datacrazy");
    registerWhatsAppProvider(fakeProvider(send));
    const { client } = makeClient({
      delivery_requests: () => ({
        id: "del1", status: "assigned", vehicle_required: "motorcycle",
        pickup_address: "Rua Coleta 10", pickup_contact_name: "Loja", pickup_contact_phone: "55888",
        delivery_address: "Rua Entrega 20", delivery_contact_name: "João", delivery_contact_phone: "55999",
      }),
      delivery_assignments: () => ({ driver_id: "d1" }),
      drivers: () => ({ phone: "55319" }),
    });
    const r = await sendNotification(client, { type: "assignment", delivery_id: "del1" }, "c");
    expect(r.ok).toBe(true);
    const body: string = send.mock.calls[0][0].body;
    expect(body).toContain("Rua Coleta 10");
    expect(body).toContain("Rua Entrega 20");
    expect(body).toContain("João");
  });
  it("sem assignment ativa → not_found", async () => {
    registerWhatsAppProvider(fakeProvider(vi.fn()));
    const { client } = makeClient({
      delivery_requests: () => ({ id: "del1", status: "assigned", vehicle_required: "motorcycle", pickup_address: "x", pickup_contact_name: null, pickup_contact_phone: "5", delivery_address: "y", delivery_contact_name: null, delivery_contact_phone: "5" }),
      delivery_assignments: () => null,
    });
    const r = await sendNotification(client, { type: "assignment", delivery_id: "del1" }, "c");
    expect(r).toEqual({ ok: false, reason: "not_found" });
  });
});

describe("sendNotification — sem provider → 501", () => {
  it("lança WhatsAppProviderNotConfiguredError", async () => {
    const { client } = makeClient({});
    await expect(sendNotification(client, { type: "otp", delivery_id: "d" }, "c")).rejects.toBeInstanceOf(WhatsAppProviderNotConfiguredError);
  });
});

describe("sendNotification — idempotência determinística (notifications.idempotency_key)", () => {
  it("mesma offer → mesma idempotency_key (replay não duplica row)", async () => {
    const send = mkSend("m", "evolution");
    registerWhatsAppProvider(fakeProvider(send));
    const { client, upserts } = makeClient({
      delivery_offers: () => ({ driver_id: "d1", driver_offer_cents: 1090, delivery_request_id: "del1", expires_at: new Date(Date.now() + 600_000).toISOString() }),
      drivers: () => ({ phone: "55319" }),
      delivery_requests: () => ({ vehicle_required: "motorcycle", priority: "standard" }),
    });
    await sendNotification(client, { type: "offer", offer_id: "of1" }, "c1");
    await sendNotification(client, { type: "offer", offer_id: "of1" }, "c2");
    const notifs = upserts.filter((u) => u.table === "notifications");
    expect(notifs).toHaveLength(2);
    expect(notifs[0].row.idempotency_key).toBe("notif:offer:of1");
    expect(notifs[1].row.idempotency_key).toBe("notif:offer:of1");
    expect((notifs[1].opts as { ignoreDuplicates: boolean }).ignoreDuplicates).toBe(true);
  });
});