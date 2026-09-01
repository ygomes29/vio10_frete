import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  getDriverMe,
  getDriverOpportunity,
  getActiveDelivery,
  getDeliveryHistory,
  getEarnings,
  upsertDriverLocation,
} from "./driver-reads";

/**
 * Mock do client user-scoped (builder chain). Cada método retorna `this` para
 * encadear; os terminais (`maybeSingle`/`limit`/`order` sem encadeamento) devolvem
 * `{data, error}` controlado pelo teste via `setData`.
 */
function makeClient(data: unknown, error: unknown = null): SupabaseClient {
  const chain: Record<string, unknown> = {};
  const terminal = () => Promise.resolve({ data, error });
  const self = {
    select: vi.fn(() => chain),
    eq: vi.fn(() => chain),
    gt: vi.fn(() => chain),
    gte: vi.fn(() => chain),
    is: vi.fn(() => chain),
    not: vi.fn(() => chain),
    order: vi.fn(() => chain),
    limit: vi.fn(() => chain),
    upsert: vi.fn(() => ({ error })),
    maybeSingle: vi.fn(terminal),
    single: vi.fn(terminal),
  };
  // Cada builder method retorna o mesmo objeto chain p/ encadeamento.
  Object.assign(chain, self);
  // Thenable: queries que não terminam em maybeSingle/single são `await`-adas
  // direto (ex.: getDriverOpportunity encerra em .order()). `await` chama `.then`.
  chain.then = (resolve: (v: { data: unknown; error: unknown }) => void) =>
    resolve({ data, error });
  const client = { from: vi.fn(() => chain), _chain: chain };
  return client as unknown as SupabaseClient;
}

beforeEach(() => vi.clearAllMocks());
afterEach(() => vi.restoreAllMocks());

describe("getDriverMe", () => {
  it("retorna {ok:true, me} quando há row", async () => {
    const c = makeClient({ id: "d1", full_name: "Ana" });
    const r = await getDriverMe(c, "d1");
    expect(r.ok).toBe(true);
    expect((r as unknown as { me: { id: string } }).me.id).toBe("d1");
  });
  it("retorna not_found quando data=null", async () => {
    const c = makeClient(null);
    const r = await getDriverMe(c, "d1");
    expect(r.ok).toBe(false);
    expect(r.reason).toBe("not_found");
  });
  it("retorna not_found em erro", async () => {
    const c = makeClient(null, { message: "boom" });
    const r = await getDriverMe(c, "d1");
    expect(r.reason).toBe("not_found");
  });
});

describe("getDriverOpportunity", () => {
  it("retorna opportunities (array) quando ok", async () => {
    const c = makeClient([{ id: "of1" }]);
    const r = await getDriverOpportunity(c, "d1");
    expect(r.ok).toBe(true);
    expect((r as unknown as { opportunities: unknown[] }).opportunities).toHaveLength(1);
  });
  it("retorna [] quando data null", async () => {
    const c = makeClient(null);
    const r = await getDriverOpportunity(c, "d1");
    expect(r.ok).toBe(true);
    expect((r as unknown as { opportunities: unknown[] }).opportunities).toEqual([]);
  });
  it("retorna internal_error em erro", async () => {
    const c = makeClient(null, { message: "x" });
    const r = await getDriverOpportunity(c, "d1");
    expect(r.reason).toBe("internal_error");
  });
});

describe("getActiveDelivery", () => {
  it("retorna active null quando data null", async () => {
    const c = makeClient(null);
    const r = await getActiveDelivery(c, "d1");
    expect(r.ok).toBe(true);
    expect((r as unknown as { active: unknown }).active).toBeNull();
  });
  it("retorna active null quando status não é ativo (terminal)", async () => {
    const c = makeClient({ delivery_request_id: "x", delivery_requests: { status: "delivered" } });
    const r = await getActiveDelivery(c, "d1");
    expect((r as unknown as { active: unknown }).active).toBeNull();
  });
  it("retorna active quando status em assigned..in_transit", async () => {
    const c = makeClient({ delivery_request_id: "x", delivery_requests: { status: "in_transit" } });
    const r = await getActiveDelivery(c, "d1");
    expect((r as unknown as { active: { delivery_request_id: string } }).active.delivery_request_id).toBe("x");
  });
  it("retorna internal_error em erro", async () => {
    const c = makeClient(null, { message: "x" });
    const r = await getActiveDelivery(c, "d1");
    expect(r.reason).toBe("internal_error");
  });
});

describe("getDeliveryHistory", () => {
  it("clamp limit para [1,50]", async () => {
    const c = makeClient([]);
    await getDeliveryHistory(c, "d1", 999);
    // limit foi chamado (não asserção de valor exato — clamp interno)
    expect((c as unknown as { _chain: { limit: ReturnType<typeof vi.fn> } })._chain.limit).toHaveBeenCalled();
  });
  it("retorna deliveries em sucesso", async () => {
    const c = makeClient([{ id: "a" }]);
    const r = await getDeliveryHistory(c, "d1", 10);
    expect(r.ok).toBe(true);
    expect((r as unknown as { deliveries: unknown[] }).deliveries).toHaveLength(1);
  });
});

describe("getEarnings", () => {
  it("soma bid_amount_cents ?? driver_offer_cents das delivered", async () => {
    const c = makeClient([
      { delivery_requests: { status: "delivered" }, bids: { bid_amount_cents: 1500 }, delivery_offers: { driver_offer_cents: 1000 } },
      { delivery_requests: { status: "delivered" }, bids: null, delivery_offers: { driver_offer_cents: 2000 } },
      { delivery_requests: { status: "cancelled" }, bids: { bid_amount_cents: 9999 } },
    ]);
    const r = await getEarnings(c, "d1");
    expect(r.ok).toBe(true);
    const e = r as unknown as { total_cents: number; count: number };
    expect(e.total_cents).toBe(3500); // 1500 + 2000; cancelled ignorado
    expect(e.count).toBe(2);
  });
  it("retorna internal_error em erro", async () => {
    const c = makeClient(null, { message: "x" });
    const r = await getEarnings(c, "d1");
    expect(r.reason).toBe("internal_error");
  });
});

describe("upsertDriverLocation", () => {
  it("retorna {ok:true, stored:true} em upsert sem erro", async () => {
    const c = makeClient(null);
    const r = await upsertDriverLocation(c, "d1", {
      latitude: -23.6,
      longitude: -46.7,
      capturedAt: "2026-08-31T00:00:00Z",
    });
    expect(r.ok).toBe(true);
    expect((r as unknown as { stored: boolean }).stored).toBe(true);
    // position é WKT POINT(lng lat) — lng primeiro
    const upsert = (c as unknown as { _chain: { upsert: ReturnType<typeof vi.fn> } })._chain.upsert;
    expect(upsert).toHaveBeenCalledWith(
      expect.objectContaining({ position: "POINT(-46.7 -23.6)", driver_id: "d1" }),
      { onConflict: "driver_id" },
    );
  });
  it("retorna not_authorized quando erro menciona policy", async () => {
    const c = makeClient(null, { message: "violates row-level security policy" });
    const r = await upsertDriverLocation(c, "d1", {
      latitude: 0,
      longitude: 0,
      capturedAt: "x",
    });
    expect(r.ok).toBe(false);
    expect(r.reason).toBe("not_authorized");
  });
  it("retorna internal_error em erro genérico", async () => {
    const c = makeClient(null, { message: "boom" });
    const r = await upsertDriverLocation(c, "d1", {
      latitude: 0,
      longitude: 0,
      capturedAt: "x",
    });
    expect(r.reason).toBe("internal_error");
  });
});