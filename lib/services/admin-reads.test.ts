import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  getOverview,
  listDeliveries,
  getDeliveryDetail,
  getDeliveryPositions,
  parsePointPosition,
} from "./admin-reads";

/**
 * Mock multi-tabela: `from(table)` retorna um chain independente por tabela, cada
 * um com seu `{data, error}`. Suporta `select/eq/gte/gte/order/limit/range/
 * maybeSingle` + thenable (queries que terminam em .order()/.range() sem
 * maybeSingle são `await`-adas direto).
 */
function makeMultiClient(tables: Record<string, { data: unknown; error?: unknown }>): SupabaseClient {
  function chainFor(table: string) {
    const entry = tables[table] ?? { data: null };
    const data = entry.data;
    const error = entry.error ?? null;
    const terminal = () => Promise.resolve({ data, error });
    const chain: Record<string, unknown> = {};
    const self = {
      select: vi.fn(() => chain),
      eq: vi.fn(() => chain),
      gte: vi.fn(() => chain),
      not: vi.fn(() => chain),
      is: vi.fn(() => chain),
      order: vi.fn(() => chain),
      limit: vi.fn(() => chain),
      range: vi.fn(() => chain),
      maybeSingle: vi.fn(terminal),
      single: vi.fn(terminal),
    };
    Object.assign(chain, self);
    chain.then = (resolve: (v: { data: unknown; error: unknown }) => void) => resolve({ data, error });
    return chain;
  }
  const client = { from: vi.fn((t: string) => chainFor(t)) };
  return client as unknown as SupabaseClient;
}

beforeEach(() => vi.clearAllMocks());
afterEach(() => vi.restoreAllMocks());

describe("parsePointPosition", () => {
  it("GeoJSON {coordinates:[lng,lat]} → {lat,lng} (lng primeiro)", () => {
    expect(parsePointPosition({ type: "Point", coordinates: [-44.0, -22.5] })).toEqual({
      lat: -22.5,
      lng: -44.0,
    });
  });
  it("WKT 'POINT(lng lat)' fallback → {lat,lng}", () => {
    expect(parsePointPosition("POINT(-44.0 -22.5)")).toEqual({ lat: -22.5, lng: -44.0 });
  });
  it("null → null", () => {
    expect(parsePointPosition(null)).toBeNull();
  });
  it("objeto sem coordinates → null", () => {
    expect(parsePointPosition({ foo: 1 })).toBeNull();
  });
  it("coords não-numéricos → null", () => {
    expect(parsePointPosition({ type: "Point", coordinates: ["x", "y"] })).toBeNull();
  });
  it("EWKB hex (formato default PostgREST/Supabase p/ geography) → {lat,lng}", () => {
    // Constrói EWKB de Point(lng=-44.0, lat=-22.5) SRID 4326 little-endian —
    // formato real retornado pelo PostgREST (confirmado live Sessão 18).
    const b = Buffer.alloc(25);
    b[0] = 0x01; // little-endian
    b.writeUInt32LE(0x20000001, 1); // Point + SRID flag
    b.writeUInt32LE(4326, 5);
    b.writeDoubleLE(-44.0, 9); // lng primeiro
    b.writeDoubleLE(-22.5, 17); // lat
    expect(parsePointPosition(b.toString("hex"))).toEqual({ lat: -22.5, lng: -44.0 });
  });
  it("EWKB big-endian → {lat,lng}", () => {
    const b = Buffer.alloc(25);
    b[0] = 0x00; // big-endian
    b.writeUInt32BE(0x20000001, 1);
    b.writeUInt32BE(4326, 5);
    b.writeDoubleBE(-43.5, 9);
    b.writeDoubleBE(-20.25, 17);
    expect(parsePointPosition(b.toString("hex"))).toEqual({ lat: -20.25, lng: -43.5 });
  });
  it("EWKB sem SRID (type=1) → {lat,lng}", () => {
    const b = Buffer.alloc(21);
    b[0] = 0x01;
    b.writeUInt32LE(1, 1); // Point, sem flag SRID
    b.writeDoubleLE(-44.0, 5);
    b.writeDoubleLE(-22.5, 13);
    expect(parsePointPosition(b.toString("hex"))).toEqual({ lat: -22.5, lng: -44.0 });
  });
  it("EWKB não-Point (LineString type=2) → null", () => {
    const b = Buffer.alloc(5);
    b[0] = 0x01;
    b.writeUInt32LE(0x20000002, 1); // LineString + SRID
    expect(parsePointPosition(b.toString("hex"))).toBeNull();
  });
});

describe("getOverview", () => {
  it("agrega counts por status + drivers por disponibilidade + volume do dia", async () => {
    const today = new Date();
    today.setHours(12, 0, 0, 0);
    const iso = today.toISOString();
    const c = makeMultiClient({
      delivery_requests: {
        data: [
          { id: "r1", status: "assigned", created_at: iso, delivered_at: null, cancelled_at: null, failed_reason: null, cancelled_reason: null, delivery_quotes: { customer_price_cents: 1090 } },
          { id: "r2", status: "in_transit", created_at: iso, delivered_at: null, cancelled_at: null, failed_reason: null, cancelled_reason: null, delivery_quotes: null },
          { id: "r3", status: "delivered", created_at: iso, delivered_at: iso, cancelled_at: null, failed_reason: null, cancelled_reason: null, delivery_quotes: { customer_price_cents: 2090 } },
          { id: "r4", status: "cancelled", created_at: iso, delivered_at: null, cancelled_at: "2026-01-01T00:00:00Z", failed_reason: null, cancelled_reason: "no_driver", delivery_quotes: null },
        ],
      },
      drivers: {
        data: [
          { id: "d1", account_status: "active", current_availability_status: "online" },
          { id: "d2", account_status: "active", current_availability_status: "busy" },
          { id: "d3", account_status: "pending", current_availability_status: "offline" },
        ],
      },
    });
    const r = await getOverview(c);
    expect(r.ok).toBe(true);
    const o = r as unknown as {
      deliveries_by_status: { active: Record<string, number>; terminal: Record<string, number> };
      drivers: { active_total: number; by_availability: Record<string, number> };
      delivered_today: { count: number; total_cents: number };
      failures: unknown[];
    };
    expect(o.deliveries_by_status.active.assigned).toBe(1);
    expect(o.deliveries_by_status.active.in_transit).toBe(1);
    expect(o.deliveries_by_status.terminal.delivered).toBe(1);
    expect(o.deliveries_by_status.terminal.cancelled).toBe(1);
    expect(o.drivers.active_total).toBe(2); // pending excluído
    expect(o.drivers.by_availability.online).toBe(1);
    expect(o.drivers.by_availability.busy).toBe(1);
    expect(o.delivered_today.count).toBe(1);
    expect(o.delivered_today.total_cents).toBe(2090);
    expect(o.failures).toHaveLength(1);
  });

  it("erro em delivery_requests → internal_error (ou not_authorized em policy)", async () => {
    const c = makeMultiClient({
      delivery_requests: { data: null, error: { message: "boom" } },
      drivers: { data: [] },
    });
    const r = await getOverview(c);
    expect(r.ok).toBe(false);
    expect(r.reason).toBe("internal_error");
  });

  it("erro de policy → not_authorized", async () => {
    const c = makeMultiClient({
      delivery_requests: { data: null, error: { message: "permission denied" } },
      drivers: { data: [] },
    });
    const r = await getOverview(c);
    expect(r.reason).toBe("not_authorized");
  });
});

describe("listDeliveries", () => {
  it("pagina: fetch limit+1, has_more quando excede", async () => {
    const rows = Array.from({ length: 26 }, (_, i) => ({ id: `r${i}`, status: "assigned", created_at: "2026-01-01T00:00:00Z", pickup_address: "a", delivery_address: "b", vehicle_required: "motorcycle" }));
    const c = makeMultiClient({ delivery_requests: { data: rows } });
    const r = await listDeliveries(c, { limit: 25, offset: 0 });
    expect(r.ok).toBe(true);
    expect((r as unknown as { deliveries: unknown[]; has_more: boolean }).deliveries).toHaveLength(25);
    expect((r as unknown as { has_more: boolean }).has_more).toBe(true);
  });

  it("aplica filtro status (eq chamado)", async () => {
    const c = makeMultiClient({ delivery_requests: { data: [] } });
    await listDeliveries(c, { status: "assigned", limit: 25, offset: 0 });
    const from = (c as unknown as { from: ReturnType<typeof vi.fn> }).from;
    const chain = from.mock.results[0].value as { eq: ReturnType<typeof vi.fn> };
    expect(chain.eq).toHaveBeenCalledWith("status", "assigned");
  });

  it("limit clampado a [1,100]", async () => {
    const c = makeMultiClient({ delivery_requests: { data: [] } });
    const r = await listDeliveries(c, { limit: 999, offset: 0 });
    expect((r as unknown as { limit: number }).limit).toBe(100);
  });
});

describe("getDeliveryDetail", () => {
  it("retorna delivery + ordena timeline por created_at", async () => {
    const data = {
      id: "r1",
      status: "in_transit",
      pickup_latitude: -22.5,
      pickup_longitude: -44.0,
      delivery_latitude: -22.6,
      delivery_longitude: -44.1,
      delivery_events: [
        { id: "e2", event_type: "in_transit", created_at: "2026-01-02T00:00:00Z" },
        { id: "e1", event_type: "delivery_created", created_at: "2026-01-01T00:00:00Z" },
      ],
    };
    const c = makeMultiClient({ delivery_requests: { data } });
    const r = await getDeliveryDetail(c, "r1");
    expect(r.ok).toBe(true);
    const d = (r as unknown as { delivery: { delivery_events: { id: string }[] } }).delivery;
    expect(d.delivery_events[0].id).toBe("e1");
    expect(d.delivery_events[1].id).toBe("e2");
  });

  it("data null → not_found", async () => {
    const c = makeMultiClient({ delivery_requests: { data: null } });
    const r = await getDeliveryDetail(c, "nope");
    expect(r.ok).toBe(false);
    expect(r.reason).toBe("not_found");
  });
});

describe("getDeliveryPositions", () => {
  it("pickup/delivery diretos + driver via parse GeoJSON do driver_locations", async () => {
    const data = {
      id: "r1",
      status: "in_transit",
      pickup_latitude: -22.5,
      pickup_longitude: -44.0,
      delivery_latitude: -22.6,
      delivery_longitude: -44.1,
      delivery_assignments: [
        {
          status: "active",
          drivers: {
            full_name: "Ana",
            driver_locations: { position: { type: "Point", coordinates: [-44.05, -22.55] }, captured_at: "2026-01-01T00:00:00Z", accuracy_m: 10 },
          },
        },
      ],
    };
    const c = makeMultiClient({ delivery_requests: { data } });
    const r = await getDeliveryPositions(c, "r1");
    expect(r.ok).toBe(true);
    const p = r as unknown as { pickup: { lat: number }; delivery: { lat: number }; driver: { full_name: string; position: { lat: number; lng: number } | null } };
    expect(p.pickup.lat).toBe(-22.5);
    expect(p.delivery.lat).toBe(-22.6);
    expect(p.driver.full_name).toBe("Ana");
    expect(p.driver.position).toEqual({ lat: -22.55, lng: -44.05 });
  });

  it("sem assignment ativa → driver null (mas pickup/delivery presentes)", async () => {
    const data = {
      id: "r1",
      status: "quoted",
      pickup_latitude: -22.5,
      pickup_longitude: -44.0,
      delivery_latitude: -22.6,
      delivery_longitude: -44.1,
      delivery_assignments: [],
    };
    const c = makeMultiClient({ delivery_requests: { data } });
    const r = await getDeliveryPositions(c, "r1");
    const p = r as unknown as { driver: null; pickup: { lat: number } };
    expect(p.driver).toBeNull();
    expect(p.pickup.lat).toBe(-22.5);
  });

  it("WKT em position → parse fallback", async () => {
    const data = {
      id: "r1",
      status: "in_transit",
      pickup_latitude: 0,
      pickup_longitude: 0,
      delivery_latitude: 0,
      delivery_longitude: 0,
      delivery_assignments: [{
        status: "active",
        drivers: { full_name: "Bo", driver_locations: { position: "POINT(-44.0 -22.5)", captured_at: "t", accuracy_m: null } },
      }],
    };
    const c = makeMultiClient({ delivery_requests: { data } });
    const r = await getDeliveryPositions(c, "r1");
    const p = r as unknown as { driver: { position: { lat: number; lng: number } | null } };
    expect(p.driver.position).toEqual({ lat: -22.5, lng: -44.0 });
  });

  it("data null → not_found", async () => {
    const c = makeMultiClient({ delivery_requests: { data: null } });
    const r = await getDeliveryPositions(c, "nope");
    expect(r.reason).toBe("not_found");
  });
});