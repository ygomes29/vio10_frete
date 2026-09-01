import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import type { SupabaseClient } from "@supabase/supabase-js";
import { getBusinessMe, getBusinessOverview } from "./business-reads";

/**
 * Mock multi-tabela + rpc. Espelho de admin-reads.test (makeMultiClient), estendido
 * p/ suportar `client.rpc(name)` (my_org_memberships) usado por getBusinessMe.
 * `from(table)` retorna chain independente por tabela c/ thenable terminal.
 */
function makeMultiClient(
  tables: Record<string, { data: unknown; error?: unknown }>,
  rpcs: Record<string, { data: unknown; error?: unknown }> = {},
): SupabaseClient {
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
    chain.then = (resolve: (v: { data: unknown; error: unknown }) => void) =>
      resolve({ data, error });
    return chain;
  }
  const client = {
    from: vi.fn((t: string) => chainFor(t)),
    rpc: vi.fn((name: string) => {
      const r = rpcs[name] ?? { data: null };
      return Promise.resolve({ data: r.data, error: r.error ?? null });
    }),
  };
  return client as unknown as SupabaseClient;
}

beforeEach(() => vi.clearAllMocks());
afterEach(() => vi.restoreAllMocks());

describe("getBusinessMe", () => {
  it("retorna memberships + organizations + businesses + locations", async () => {
    const c = makeMultiClient(
      {
        organizations: { data: [{ id: "org-1", name: "Padaria", document: "123" }] },
        businesses: { data: [{ id: "biz-1", organization_id: "org-1", name: "Loja", status: "active" }] },
        business_locations: {
          data: [{ id: "loc-1", business_id: "biz-1", label: "Matriz", address: "Rua X", is_active: true }],
        },
      },
      {
        my_org_memberships: {
          data: [{ organization_id: "org-1", role: "business_owner" }],
        },
      },
    );
    const r = await getBusinessMe(c);
    expect(r.ok).toBe(true);
    const p = r as unknown as {
      memberships: { organization_id: string; role: string }[];
      organizations: unknown[];
      businesses: unknown[];
      locations: unknown[];
    };
    expect(p.memberships).toHaveLength(1);
    expect(p.memberships[0].role).toBe("business_owner");
    expect(p.organizations).toHaveLength(1);
    expect(p.businesses).toHaveLength(1);
    expect(p.locations).toHaveLength(1);
  });

  it("sem membership → memberships vazias (não é erro — driver autenticado sem org)", async () => {
    const c = makeMultiClient(
      {
        organizations: { data: [] },
        businesses: { data: [] },
        business_locations: { data: [] },
      },
      { my_org_memberships: { data: [] } },
    );
    const r = await getBusinessMe(c);
    expect(r.ok).toBe(true);
    const p = r as unknown as { memberships: unknown[] };
    expect(p.memberships).toEqual([]);
  });

  it("erro de policy no my_org_memberships → not_authorized", async () => {
    const c = makeMultiClient(
      {
        organizations: { data: [] },
        businesses: { data: [] },
        business_locations: { data: [] },
      },
      { my_org_memberships: { data: null, error: { message: "permission denied for table" } } },
    );
    const r = await getBusinessMe(c);
    expect(r.ok).toBe(false);
    expect(r.reason).toBe("not_authorized");
  });

  it("erro genérico num select → internal_error", async () => {
    const c = makeMultiClient(
      {
        organizations: { data: null, error: { message: "relation does not exist" } },
        businesses: { data: [] },
        business_locations: { data: [] },
      },
      { my_org_memberships: { data: [] } },
    );
    const r = await getBusinessMe(c);
    expect(r.ok).toBe(false);
    expect(r.reason).toBe("internal_error");
  });
});

describe("getBusinessOverview", () => {
  const today = new Date();
  today.setHours(12, 0, 0, 0);
  const iso = today.toISOString();

  it("agrega ativas/terminais por status + entregues hoje + volume (centavos inteiros)", async () => {
    const c = makeMultiClient({
      delivery_requests: {
        data: [
          { id: "r1", status: "assigned", created_at: iso, delivered_at: null, cancelled_at: null, failed_reason: null, cancelled_reason: null, delivery_quotes: { customer_price_cents: 1090 } },
          { id: "r2", status: "in_transit", created_at: iso, delivered_at: null, cancelled_at: null, failed_reason: null, cancelled_reason: null, delivery_quotes: null },
          { id: "r3", status: "delivered", created_at: iso, delivered_at: iso, cancelled_at: null, failed_reason: null, cancelled_reason: null, delivery_quotes: { customer_price_cents: 2090 } },
          { id: "r4", status: "cancelled", created_at: iso, delivered_at: null, cancelled_at: iso, failed_reason: null, cancelled_reason: "no_driver", delivery_quotes: null },
        ],
      },
    });
    const r = await getBusinessOverview(c);
    expect(r.ok).toBe(true);
    const o = r as unknown as {
      window_hours: number;
      deliveries_by_status: { active: Record<string, number>; terminal: Record<string, number> };
      delivered_today: { count: number; total_cents: number };
      failures: { id: string; status: string; reason: string | null }[];
    };
    expect(o.window_hours).toBe(72);
    expect(o.deliveries_by_status.active.assigned).toBe(1);
    expect(o.deliveries_by_status.active.in_transit).toBe(1);
    expect(o.deliveries_by_status.terminal.delivered).toBe(1);
    expect(o.deliveries_by_status.terminal.cancelled).toBe(1);
    expect(o.delivered_today.count).toBe(1);
    expect(o.delivered_today.total_cents).toBe(2090); // inteiro, não float
    expect(o.failures).toHaveLength(1);
    expect(o.failures[0].reason).toBe("no_driver");
  });

  it("delivered ontem (fora do dia) → NÃO conta em delivered_today", async () => {
    const yesterday = new Date();
    yesterday.setDate(yesterday.getDate() - 1);
    yesterday.setHours(12, 0, 0, 0);
    const c = makeMultiClient({
      delivery_requests: {
        data: [
          { id: "r1", status: "delivered", created_at: yesterday.toISOString(), delivered_at: yesterday.toISOString(), cancelled_at: null, failed_reason: null, cancelled_reason: null, delivery_quotes: { customer_price_cents: 5000 } },
        ],
      },
    });
    const r = await getBusinessOverview(c);
    expect(r.ok).toBe(true);
    const o = r as unknown as { delivered_today: { count: number; total_cents: number } };
    expect(o.delivered_today.count).toBe(0);
    expect(o.delivered_today.total_cents).toBe(0);
  });

  it("delivery_quotes como array → usa primeiro elemento", async () => {
    const c = makeMultiClient({
      delivery_requests: {
        data: [
          { id: "r1", status: "delivered", created_at: iso, delivered_at: iso, cancelled_at: null, failed_reason: null, cancelled_reason: null, delivery_quotes: [{ customer_price_cents: 3090 }, { customer_price_cents: 999 }] },
        ],
      },
    });
    const r = await getBusinessOverview(c);
    expect(r.ok).toBe(true);
    const o = r as unknown as { delivered_today: { total_cents: number } };
    expect(o.delivered_today.total_cents).toBe(3090);
  });

  it("falhas limitadas a 20 (slice)", async () => {
    const rows = Array.from({ length: 25 }, (_, i) => ({
      id: `f${i}`,
      status: "failed",
      created_at: iso,
      delivered_at: null,
      cancelled_at: null,
      failed_reason: `err${i}`,
      cancelled_reason: null,
      delivery_quotes: null,
    }));
    const c = makeMultiClient({ delivery_requests: { data: rows } });
    const r = await getBusinessOverview(c);
    expect(r.ok).toBe(true);
    const o = r as unknown as { failures: unknown[] };
    expect(o.failures).toHaveLength(20);
  });

  it("erro de policy → not_authorized", async () => {
    const c = makeMultiClient({
      delivery_requests: { data: null, error: { message: "permission denied" } },
    });
    const r = await getBusinessOverview(c);
    expect(r.ok).toBe(false);
    expect(r.reason).toBe("not_authorized");
  });
});