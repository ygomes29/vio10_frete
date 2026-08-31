import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { createHmac } from "node:crypto";
import { handleWebhookPost } from "./webhook-handler";
import type { SupabaseClient } from "@supabase/supabase-js";

const SECRET = "dc-webhook-secret-XXXXXXXXXXXXXXXXXXXXXX";

function sign(body: string): string {
  return createHmac("sha256", SECRET).update(body).digest("hex");
}

/**
 * Mock do client system. Apenas `from("webhook_events")` é exercitado.
 * Cadeias:
 *   upsert: `.from().upsert(row, opts).select("id").maybeSingle()` → {data: upsertRow}
 *   update: `.from().update(patch).eq("id", id)` → thenable (await / .then)
 * `updates` captura patches de status p/ asserção.
 */
type UpsertRow = { id: string } | null;

function makeClient(opts: { upsertRow?: UpsertRow }): { client: SupabaseClient; updates: { status: string }[] } {
  const updates: { status: string }[] = [];
  const client = {
    from: () => {
      const patchRef: { patch: Record<string, unknown> | null } = { patch: null };
      const b = {
        select: () => b,
        upsert: () => b,
        update: (patch: Record<string, unknown>) => {
          patchRef.patch = patch;
          return b;
        },
        eq: () => {
          // registra status quando o await/then resolve (cadeia de update concluída)
          if (patchRef.patch && typeof patchRef.patch.status === "string") {
            updates.push({ status: patchRef.patch.status as string });
          }
          // thenable que resolve undefined (compatível c/ await e .then(fn, fn))
          return Promise.resolve(undefined);
        },
        maybeSingle: async () => ({ data: opts.upsertRow ?? null, error: null }),
      };
      return b;
    },
  } as unknown as SupabaseClient;
  return { client, updates };
}

// Mocka createSystemClient p/ retornar nosso client controlado.
let nextClient: SupabaseClient | null = null;
vi.mock("@/lib/supabase/system-client", () => ({
  createSystemClient: () => nextClient,
}));

beforeEach(() => {
  process.env.DATACRAZY_WEBHOOK_SECRET = SECRET;
  nextClient = null;
});

afterEach(() => {
  delete process.env.DATACRAZY_WEBHOOK_SECRET;
  vi.restoreAllMocks();
});

function makeRequest(body: string, headers: Record<string, string> = {}): Request {
  return new Request("http://localhost/api/webhooks/datacrazy", {
    method: "POST",
    headers: { "content-type": "application/json", "x-datacrazy-event-id": "evt-1", ...headers },
    body,
  });
}

const externalId = (request: Request) => request.headers.get("x-datacrazy-event-id");

describe("handleWebhookPost", () => {
  it("signature inválida → 401, NÃO dedup/roteia", async () => {
    const route = vi.fn();
    const res = await handleWebhookPost(makeRequest("{}", { "x-datacrazy-signature": "bad" }), {
      source: "datacrazy",
      externalId,
      route,
    });
    expect(res.status).toBe(401);
    expect(route).not.toHaveBeenCalled();
  });

  it("signature ausente → 401", async () => {
    const route = vi.fn();
    const res = await handleWebhookPost(makeRequest("{}"), { source: "datacrazy", externalId, route });
    expect(res.status).toBe(401);
    expect(route).not.toHaveBeenCalled();
  });

  it("external_id ausente → 400", async () => {
    const body = "{}";
    const req = new Request("http://localhost/api/webhooks/datacrazy", {
      method: "POST",
      headers: { "content-type": "application/json", "x-datacrazy-signature": sign(body) },
      body,
    });
    const res = await handleWebhookPost(req, { source: "datacrazy", externalId, route: vi.fn() });
    expect(res.status).toBe(400);
  });

  it("body JSON inválido → 400 (signature válida)", async () => {
    const body = "{bad";
    const req = makeRequest(body, { "x-datacrazy-signature": sign(body) });
    const res = await handleWebhookPost(req, { source: "datacrazy", externalId, route: vi.fn() });
    expect(res.status).toBe(400);
  });

  it("novo evento → roteia + marca processed → 200", async () => {
    const body = JSON.stringify({ intent: "offer_response", driver_id: "d1" });
    const { client, updates } = makeClient({ upsertRow: { id: "we-1" } });
    nextClient = client;
    const route = vi.fn(async () => undefined);
    const res = await handleWebhookPost(makeRequest(body, { "x-datacrazy-signature": sign(body) }), {
      source: "datacrazy",
      externalId,
      route,
    });
    expect(res.status).toBe(200);
    expect(route).toHaveBeenCalledTimes(1);
    expect(updates).toEqual([{ status: "processed" }]);
  });

  it("duplicado (upsert não inseriu) → 200 idempotent_replay, NÃO roteia", async () => {
    const body = JSON.stringify({ intent: "offer_response" });
    const { client } = makeClient({ upsertRow: null }); // já existe
    nextClient = client;
    const route = vi.fn();
    const res = await handleWebhookPost(makeRequest(body, { "x-datacrazy-signature": sign(body) }), {
      source: "datacrazy",
      externalId,
      route,
    });
    expect(res.status).toBe(200);
    const j = await res.json();
    expect(j.reason).toBe("idempotent_replay");
    expect(route).not.toHaveBeenCalled();
  });

  it("route lança erro → 200 routed_with_error (webhook não pode depender), marca failed", async () => {
    const body = JSON.stringify({ intent: "unknown_intent" });
    const { client, updates } = makeClient({ upsertRow: { id: "we-2" } });
    nextClient = client;
    const route = vi.fn(async () => {
      throw new Error("route boom");
    });
    const res = await handleWebhookPost(makeRequest(body, { "x-datacrazy-signature": sign(body) }), {
      source: "datacrazy",
      externalId,
      route,
    });
    expect(res.status).toBe(200);
    const j = await res.json();
    expect(j.reason).toBe("routed_with_error");
    expect(updates).toEqual([{ status: "failed" }]);
  });
});