import { describe, it, expect, vi } from "vitest";
import { withIdempotency, InFlightError } from "./ledger";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { RpcResult } from "@/lib/rpc/result";

/**
 * Mock do SupabaseClient para o ledger. Apenas o caminho `from("integration_events")`
 * é exercitado. `selectRows` é consumido FIFO a cada `select().maybeSingle()`.
 * `upsertRow` é retornado por `upsert().select().maybeSingle()`.
 */
type Row = { id: string; result: unknown; status: string } | null;

function makeClient(opts: { selectRows?: Row[]; upsertRow?: { id: string } | null }): SupabaseClient {
  const selectQueue = [...(opts.selectRows ?? [])];
  const builder = (kind: "select" | "upsert" | "update") => {
    const b = {
      select: () => builder(kind === "upsert" ? "upsert" : "select"),
      eq: () => b,
      upsert: () => builder("upsert"),
      update: () => builder("update"),
      maybeSingle: () => {
        if (kind === "upsert") return Promise.resolve({ data: opts.upsertRow ?? null });
        if (kind === "update") return Promise.resolve({ data: null, error: null });
        return Promise.resolve({ data: selectQueue.shift() ?? null });
      },
    };
    return b;
  };
  return { from: () => builder("select") } as unknown as SupabaseClient;
}

const OK: RpcResult = { ok: true, reason: null, delivery_request_id: "d1" };

describe("withIdempotency", () => {
  it("skip: sem chave de dedup → executa fn uma vez, sem tocar o ledger", async () => {
    const client = makeClient({});
    const fn = vi.fn(async () => OK);
    const res = await withIdempotency(client, { source: "internal-api" }, fn);
    expect(res).toEqual(OK);
    expect(fn).toHaveBeenCalledTimes(1);
  });

  it("run: primeira call claima, executa e grava resultado", async () => {
    const client = makeClient({ selectRows: [null], upsertRow: { id: "tok-1" } });
    const fn = vi.fn(async () => OK);
    const res = await withIdempotency(client, { source: "internal-api", idempotencyKey: "k1" }, fn);
    expect(res).toEqual(OK);
    expect(fn).toHaveBeenCalledTimes(1);
  });

  it("replay: já processado → retorna resultado cacheado, NÃO re-executa fn", async () => {
    const client = makeClient({
      selectRows: [{ id: "tok-1", result: OK, status: "processed" }],
    });
    const fn = vi.fn(async () => ({ ok: true, reason: null, should_not: "run" } as RpcResult));
    const res = await withIdempotency(client, { source: "internal-api", idempotencyKey: "k1" }, fn);
    expect(res).toEqual(OK);
    expect(fn).not.toHaveBeenCalled();
  });

  it("in_flight: claim pendente → lança InFlightError (409)", async () => {
    const client = makeClient({
      selectRows: [{ id: "tok-1", result: null, status: "pending" }],
    });
    const fn = vi.fn(async () => OK);
    await expect(
      withIdempotency(client, { source: "internal-api", idempotencyKey: "k1" }, fn),
    ).rejects.toBeInstanceOf(InFlightError);
    expect(fn).not.toHaveBeenCalled();
  });

  it("race: upsert conflita (data null) → recheck acha pending → in_flight", async () => {
    const client = makeClient({
      selectRows: [null, { id: "tok-x", result: null, status: "pending" }],
      upsertRow: null, // conflito: outra call inseriu
    });
    const fn = vi.fn(async () => OK);
    await expect(
      withIdempotency(client, { source: "internal-api", idempotencyKey: "k1" }, fn),
    ).rejects.toBeInstanceOf(InFlightError);
    expect(fn).not.toHaveBeenCalled();
  });

  it("externalEventId funciona como chave de dedup (replay)", async () => {
    const client = makeClient({
      selectRows: [{ id: "tok-2", result: OK, status: "processed" }],
    });
    const fn = vi.fn(async () => OK);
    const res = await withIdempotency(client, { source: "datacrazy", externalEventId: "evt-9" }, fn);
    expect(res).toEqual(OK);
    expect(fn).not.toHaveBeenCalled();
  });

  it("idempotencyKey tem precedência sobre externalEventId", async () => {
    // Se idempotencyKey presente, select usa coluna idempotency_key; replay por ela.
    const client = makeClient({
      selectRows: [{ id: "tok-1", result: OK, status: "processed" }],
    });
    const fn = vi.fn(async () => OK);
    await withIdempotency(
      client,
      { source: "internal-api", idempotencyKey: "k1", externalEventId: "e1" },
      fn,
    );
    expect(fn).not.toHaveBeenCalled();
  });
});